// PluginDedupeTests.swift
//
// MCP connection ownership and install-moment dedupe.
// Covers PluginDetector.isPluginInstalled/isPluginEnabled/ownsConnection,
// MCPEntryClassifier.classify (including its positive shape check, Adams
// #2), and Installer.dedupeDirectEntry/uninstall's ownership-aware removal —
// the four-state matrix (plugin present/absent × prior direct entry
// present/absent) plus the "non-default entry survives untouched" guarantee
// and the installed-but-disabled-plugin guarantee (Adams #5).
//
// SAFETY: every test uses an injected sandbox home directory
// (makeSandboxHome/cleanupSandbox, same pattern as InstallerTests). Never
// point PluginDetector or Installer at the real ~/.claude, ~/.claude.json,
// or ~/.claude/settings.json.

import Testing
import Foundation
@testable import MootInstallerCore

@Suite("Plugin dedupe")
struct PluginDedupeTests {

    private let pluginID = "mootx01@mootx01"

    // MARK: - PluginDetector

    @Test("isPluginInstalled is false when installed_plugins.json is absent")
    func detectorFalseWhenAbsent() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        #expect(!PluginDetector.isPluginInstalled(pluginID: pluginID, homeDirectory: home))
    }

    @Test("isPluginInstalled is false when the plugin key is absent")
    func detectorFalseWhenOtherPluginsOnly() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        try writeInstalledPlugins(home: home, plugins: ["startup-advisor@awesome-skills"])
        #expect(!PluginDetector.isPluginInstalled(pluginID: pluginID, homeDirectory: home))
    }

    @Test("isPluginInstalled is false when the plugin's entry array is empty")
    func detectorFalseWhenEmptyArray() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        let path = home.appendingPathComponent(".claude/plugins/installed_plugins.json")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"version":2,"plugins":{"mootx01@mootx01":[]}}"#
            .write(to: path, atomically: true, encoding: .utf8)
        #expect(!PluginDetector.isPluginInstalled(pluginID: pluginID, homeDirectory: home))
    }

    @Test("isPluginInstalled is true when the plugin has at least one installed entry")
    func detectorTrueWhenInstalled() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        try writeInstalledPlugins(home: home, plugins: [pluginID])
        #expect(PluginDetector.isPluginInstalled(pluginID: pluginID, homeDirectory: home))
    }

    // MARK: - isPluginEnabled / ownsConnection (Adams #5)

    @Test("isPluginEnabled is false when settings.json is absent")
    func enabledFalseWhenSettingsAbsent() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        #expect(!PluginDetector.isPluginEnabled(pluginID: pluginID, homeDirectory: home))
    }

    @Test("isPluginEnabled is false when enabledPlugins is absent from settings.json")
    func enabledFalseWhenKeyAbsent() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        try writeSettings(home: home, json: #"{"editorMode":"vim"}"#)
        #expect(!PluginDetector.isPluginEnabled(pluginID: pluginID, homeDirectory: home))
    }

    @Test("isPluginEnabled is false when the plugin's entry is explicitly false")
    func enabledFalseWhenExplicitlyDisabled() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        try writeSettings(home: home, json: #"{"enabledPlugins":{"mootx01@mootx01":false}}"#)
        #expect(!PluginDetector.isPluginEnabled(pluginID: pluginID, homeDirectory: home))
    }

    @Test("isPluginEnabled is false when settings.json is malformed")
    func enabledFalseWhenMalformed() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        try writeSettings(home: home, json: "not json at all {{{")
        #expect(!PluginDetector.isPluginEnabled(pluginID: pluginID, homeDirectory: home))
    }

    @Test("isPluginEnabled is true when the plugin's entry is explicitly true")
    func enabledTrueWhenEnabled() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        try writeSettings(home: home, json: #"{"enabledPlugins":{"mootx01@mootx01":true,"startup-advisor@awesome-skills":true}}"#)
        #expect(PluginDetector.isPluginEnabled(pluginID: pluginID, homeDirectory: home))
    }

    @Test("ownsConnection is false when installed but disabled")
    func ownsConnectionFalseWhenDisabled() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        try writeInstalledPlugins(home: home, plugins: [pluginID])
        try writeSettings(home: home, json: #"{"enabledPlugins":{"mootx01@mootx01":false}}"#)
        #expect(PluginDetector.isPluginInstalled(pluginID: pluginID, homeDirectory: home))
        #expect(!PluginDetector.ownsConnection(pluginID: pluginID, homeDirectory: home))
    }

    @Test("ownsConnection is false when installed but settings.json is absent (fail closed)")
    func ownsConnectionFalseWhenSettingsAbsent() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        try writeInstalledPlugins(home: home, plugins: [pluginID])
        #expect(!PluginDetector.ownsConnection(pluginID: pluginID, homeDirectory: home))
    }

    @Test("ownsConnection is true when installed and enabled")
    func ownsConnectionTrueWhenInstalledAndEnabled() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        try writeInstalledPlugins(home: home, plugins: [pluginID])
        try writeSettings(home: home, json: #"{"enabledPlugins":{"mootx01@mootx01":true}}"#)
        #expect(PluginDetector.ownsConnection(pluginID: pluginID, homeDirectory: home))
    }

    @Test("ownsConnection is false when enabled but never installed")
    func ownsConnectionFalseWhenNotInstalled() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        try writeSettings(home: home, json: #"{"enabledPlugins":{"mootx01@mootx01":true}}"#)
        #expect(!PluginDetector.ownsConnection(pluginID: pluginID, homeDirectory: home))
    }

    /// Mirrors the exact decision InstallCommand.run() makes (Adams #5):
    /// "disabled falls back to direct wiring; enabled skips as shipped."
    /// Exercised at the Installer/PluginDetector level since InstallCommand
    /// itself lives in the `mootx01` executable target, not a library.
    @Test("disabled plugin: install falls back to normal direct wiring")
    func disabledPluginFallsBackToDirectWiring() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        let client = MCPClients.supported.first { $0.id == "claude-code" }!
        try writeInstalledPlugins(home: home, plugins: [pluginID])
        try writeSettings(home: home, json: #"{"enabledPlugins":{"mootx01@mootx01":false}}"#)

        // The exact conditional InstallCommand.run() uses.
        if PluginDetector.ownsConnection(pluginID: pluginID, homeDirectory: home) {
            Issue.record("plugin must not be considered connection-owning while disabled")
        } else {
            try Installer.install(
                client: client, binaryPath: "/usr/local/bin/mootx01",
                daemonURL: MootPaths.residentEndpointURL,
                homeDirectory: home, workingDirectory: home, local: false
            )
        }
        #expect(try directEntry(client: client, home: home) != nil,
                "disabled plugin must not block direct wiring — the client would otherwise have no connection")
    }

    @Test("enabled plugin: install skips direct wiring as shipped")
    func enabledPluginSkipsDirectWiring() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        let client = MCPClients.supported.first { $0.id == "claude-code" }!
        try writeInstalledPlugins(home: home, plugins: [pluginID])
        try writeSettings(home: home, json: #"{"enabledPlugins":{"mootx01@mootx01":true}}"#)

        if PluginDetector.ownsConnection(pluginID: pluginID, homeDirectory: home) {
            // Skip — matches InstallCommand.run()'s `continue` branch.
        } else {
            Issue.record("plugin must be considered connection-owning while installed and enabled")
        }
        #expect(try directEntry(client: client, home: home) == nil,
                "enabled plugin must skip direct wiring — no competing entry written")
    }

    /// Test double for `ClaudeCLIRunning`, local to this file — the one in
    /// InstallDepthTests.swift is `private` (file-scoped) and unreachable
    /// here. `@unchecked Sendable` is safe: driven synchronously,
    /// single-threaded.
    private final class FakeClaudeCLIRunner: ClaudeCLIRunning, @unchecked Sendable {
        private(set) var invokedArguments: [[String]] = []
        func run(arguments: [String]) -> Bool {
            invokedArguments.append(arguments)
            return true
        }
    }

    /// Wave 6, Defect A regression fixture — the exact state Bob's machine
    /// was found in: plugin installed+enabled (ownsConnection true) AND a
    /// stale stdio-era package already on disk (`.mcp.json` with
    /// `command: mootx01, args: [serve]`, from the legacy direct-entry design). Before the fix,
    /// `InstallCommand.run()`'s loop skipped the plugin-owned client via
    /// `continue` WITHOUT appending it to `installed`, so the depth pass's
    /// `installed.contains(client.displayName)` filter silently excluded
    /// claude-code — the plugin package, and Claude Code's cached snapshot
    /// of it, never converged.
    ///
    /// This drives the same two calls `run()`'s FIXED code path makes once
    /// a plugin-owned client is (correctly) counted as installed:
    /// `Installer.dedupeDirectEntry` (must find no competing direct entry)
    /// and `DepthInstaller.apply(depth: .plugin, ...)` (must rewrite the
    /// stale package to the current HTTP-shaped manifest and invoke the
    /// stranded-cache CLI-update seam, since the plugin is already
    /// installed).
    @Test("Defect A fixture: plugin-owned client with a stale on-disk package is rematerialized, not skipped")
    func pluginOwnedClientWithStalePackageIsRematerialized() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        let client = MCPClients.supported.first { $0.id == "claude-code" }!
        try writeInstalledPlugins(home: home, plugins: [pluginID])
        try writeSettings(home: home, json: #"{"enabledPlugins":{"mootx01@mootx01":true}}"#)
        #expect(PluginDetector.ownsConnection(pluginID: pluginID, homeDirectory: home),
                "fixture setup: plugin must be connection-owning")

        // Seed the stale stdio-era package Bob's machine actually had on
        // disk — from the legacy direct-entry design, before the package moved to an
        // HTTP-shaped .mcp.json.
        let host = try #require(InstallBundle.embedded.host(forClientID: "claude-code"))
        let pluginDir = DepthInstaller.pluginInstallDirectory(host: host, homeDirectory: home)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let staleMCP: [String: Any] = [
            "mcpServers": ["mootx01": ["command": "mootx01", "args": ["serve"]]]
        ]
        try JSONSerialization.data(withJSONObject: staleMCP)
            .write(to: pluginDir.appendingPathComponent(".mcp.json"))

        // Step 1 of run()'s plugin-owned branch: dedupe — no direct entry
        // exists to remove or retain, and none must be written.
        let dedupeOutcome = try Installer.dedupeDirectEntry(
            client: client, homeDirectory: home, workingDirectory: home, local: false
        )
        #expect(dedupeOutcome == .none, "no prior direct entry in this fixture; expected .none")

        // Step 2 (the fix): the depth pass now runs for this client too.
        let fake = FakeClaudeCLIRunner()
        let result = try DepthInstaller.apply(
            clientID: "claude-code", depth: .plugin, homeDirectory: home,
            binaryPath: "/safe/bin/mootx01", claudeCLIRunner: fake
        )
        guard case .plugin = result else {
            Issue.record("expected .plugin outcome, got \(result)"); return
        }

        let rewrittenData = try Data(contentsOf: pluginDir.appendingPathComponent(".mcp.json"))
        let rewritten = try JSONSerialization.jsonObject(with: rewrittenData) as? [String: Any]
        let server = (rewritten?["mcpServers"] as? [String: Any])?["mootx01"] as? [String: Any]
        #expect(server?["type"] as? String == "http",
                "the stale stdio manifest must have converged to the current HTTP-shaped entry; got: \(String(describing: rewritten))")
        #expect(server?["command"] == nil,
                "the stale bare `command: mootx01` placeholder must be gone")

        // The stranded-cache refresh must have
        // invoked the CLI-update seam, since the plugin is already installed.
        #expect(fake.invokedArguments == [["plugin", "update", "mootx01@mootx01"]],
                "rematerializing an already-installed plugin must invoke `claude plugin update`")

        // No direct entry must exist — the plugin still owns the connection.
        #expect(try directEntry(client: client, home: home) == nil,
                "a plugin-owned client must never gain a competing direct entry from the depth pass")
    }

    // MARK: - VersionSkewAdvisory

    @Test("VersionSkewAdvisory is nil when the plugin is not installed")
    func versionSkewNilWhenNoPlugin() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        #expect(VersionSkewAdvisory.compute(
            pluginID: pluginID, binaryVersion: "1.0.15", homeDirectory: home
        ) == nil)
    }

    @Test("VersionSkewAdvisory is nil when versions match")
    func versionSkewNilWhenVersionsMatch() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        try writeInstalledPlugins(home: home, plugins: [pluginID])  // stamps "1.0.15"
        #expect(VersionSkewAdvisory.compute(
            pluginID: pluginID, binaryVersion: "1.0.15", homeDirectory: home
        ) == nil)
    }

    @Test("VersionSkewAdvisory: plugin newer than binary → suggest mootx01 upgrade")
    func versionSkewPluginAheadSuggestsUpgrade() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        // Plugin is 1.0.15, binary is 1.0.11 → plugin is ahead → binary needs upgrading.
        try writeInstalledPlugins(home: home, plugins: [pluginID])  // stamps "1.0.15"
        let advisory = try #require(VersionSkewAdvisory.compute(
            pluginID: pluginID, binaryVersion: "1.0.11", homeDirectory: home
        ))
        #expect(advisory.contains("1.0.15"))
        #expect(advisory.contains("1.0.11"))
        #expect(advisory.contains("mootx01 upgrade"),
            "plugin > binary: remedy is mootx01 upgrade; got: \(advisory)")
        #expect(!advisory.contains("mootx01 install"),
            "should not suggest install when binary is the stale side; got: \(advisory)")
    }

    @Test("VersionSkewAdvisory: binary newer than plugin → suggest refreshing plugin")
    func versionSkewBinaryAheadSuggestsPluginRefresh() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        // Plugin is 1.0.15, binary is 1.0.18 → binary is ahead → plugin needs refreshing.
        try writeInstalledPlugins(home: home, plugins: [pluginID])  // stamps "1.0.15"
        let advisory = try #require(VersionSkewAdvisory.compute(
            pluginID: pluginID, binaryVersion: "1.0.18", homeDirectory: home
        ))
        #expect(advisory.contains("1.0.15"))
        #expect(advisory.contains("1.0.18"))
        #expect(advisory.contains("mootx01 install"),
            "binary > plugin: remedy is mootx01 install; got: \(advisory)")
        #expect(!advisory.contains("mootx01 upgrade"),
            "should not suggest upgrade when plugin is the stale side; got: \(advisory)")
    }

    // MARK: - MCPEntryClassifier

    @Test("an HTTP entry (no env) classifies as oursDefault")
    func classifyHTTPEntryIsOursDefault() {
        let entry: [String: Any] = ["type": "http", "url": "http://127.0.0.1:4242"]
        #expect(MCPEntryClassifier.classify(entry: entry) == .oursDefault)
    }

    @Test("a proxy/stdio entry with no env override classifies as oursDefault")
    func classifyPlainCommandEntryIsOursDefault() {
        let entry: [String: Any] = ["command": "/usr/local/bin/mootx01", "args": ["proxy"], "env": [String: Any]()]
        #expect(MCPEntryClassifier.classify(entry: entry) == .oursDefault)
    }

    @Test("an entry with MOOTX01_DATA_DIR override classifies as foreign")
    func classifyDataDirOverrideIsForeign() {
        let entry: [String: Any] = [
            "command": "/usr/local/bin/mootx01", "args": ["proxy"],
            "env": ["MOOTX01_DATA_DIR": "/Users/dev/rig-a"],
        ]
        guard case let .foreign(reason) = MCPEntryClassifier.classify(entry: entry) else {
            Issue.record("expected .foreign")
            return
        }
        #expect(reason.contains("MOOTX01_DATA_DIR"))
    }

    @Test("an entry with ARIA_MCP_SQLITE_PATH override classifies as foreign")
    func classifySqlitePathOverrideIsForeign() {
        let entry: [String: Any] = [
            "command": "/usr/local/bin/mootx01", "args": ["proxy"],
            "env": ["ARIA_MCP_SQLITE_PATH": "/Users/dev/estate.sqlite"],
        ]
        guard case let .foreign(reason) = MCPEntryClassifier.classify(entry: entry) else {
            Issue.record("expected .foreign")
            return
        }
        #expect(reason.contains("ARIA_MCP_SQLITE_PATH"))
    }

    // MARK: - Positive shape check (Adams #2)

    @Test("a malformed empty entry never classifies as oursDefault")
    func classifyMalformedEmptyEntryIsForeign() {
        let entry: [String: Any] = [:]
        guard case .foreign = MCPEntryClassifier.classify(entry: entry) else {
            Issue.record("expected .foreign for a malformed {} entry — must never be auto-removed")
            return
        }
    }

    @Test("a foreign command under our key name never classifies as oursDefault")
    func classifyForeignCommandUnderOurKeyIsForeign() {
        // Structurally valid, no env override at all — but the command does
        // not resolve to mootx01. Before the shape check this classified
        // .oursDefault purely from env absence.
        let entry: [String: Any] = ["command": "/usr/bin/some-other-server", "args": ["--stdio"]]
        guard case .foreign = MCPEntryClassifier.classify(entry: entry) else {
            Issue.record("expected .foreign for a foreign command entry under our key")
            return
        }
    }

    @Test("a mootx01 command entry without serve/proxy args never classifies as oursDefault")
    func classifyMootx01CommandWithoutRecognizedArgsIsForeign() {
        // Basename matches, but args don't match either recognized shape —
        // shouldn't happen for our own writes, so treat conservatively.
        let entry: [String: Any] = ["command": "/usr/local/bin/mootx01", "args": ["--version"]]
        guard case .foreign = MCPEntryClassifier.classify(entry: entry) else {
            Issue.record("expected .foreign for an unrecognized args shape")
            return
        }
    }

    @Test("a loopback URL on a non-default port never classifies as oursDefault")
    func classifyLoopbackURLNonstandardPortIsForeign() {
        // Structurally a loopback HTTP entry, but not on the exact port this
        // installer writes — may be a different, deliberately-scoped daemon
        // instance. Before the shape check this classified .oursDefault
        // purely from env absence (HTTP entries carry no env at all).
        let entry: [String: Any] = ["type": "http", "url": "http://127.0.0.1:9999"]
        guard case let .foreign(reason) = MCPEntryClassifier.classify(entry: entry) else {
            Issue.record("expected .foreign for a nonstandard-port loopback URL")
            return
        }
        #expect(!reason.isEmpty)
    }

    @Test("a non-loopback URL never classifies as oursDefault")
    func classifyNonLoopbackURLIsForeign() {
        let entry: [String: Any] = ["type": "http", "url": "http://example.com:4242"]
        guard case .foreign = MCPEntryClassifier.classify(entry: entry) else {
            Issue.record("expected .foreign for a non-loopback host")
            return
        }
    }

    @Test("the localhost loopback shape also classifies as oursDefault")
    func classifyLocalhostLoopbackIsOursDefault() {
        let entry: [String: Any] = ["url": "http://localhost:4242"]
        #expect(MCPEntryClassifier.classify(entry: entry) == .oursDefault)
    }

    @Test("a legacy bare serve command entry still classifies as oursDefault")
    func classifyLegacyServeCommandIsOursDefault() {
        let entry: [String: Any] = ["command": "/usr/local/bin/mootx01", "args": ["serve"], "env": [String: Any]()]
        #expect(MCPEntryClassifier.classify(entry: entry) == .oursDefault)
    }

    // MARK: - Shape check proven through the real file-write dedupe path
    // (verification-pass addendum: classify()'s label alone is by-construction
    // evidence; these round-trip a shape-mismatched entry through a REAL temp
    // config file and the full dedupeDirectEntry pass with plugin-present
    // state, proving the file survives untouched — not just that classify()
    // returns the right label in isolation.)

    @Test("dedupeDirectEntry round-trip: a malformed {} entry under our key survives untouched, plugin present")
    func dedupeRoundTripMalformedEntrySurvives() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        let client = MCPClients.supported.first { $0.id == "claude-code" }!
        let configURL = home.appendingPathComponent(client.configPath)

        // A malformed entry: present under our server name, but an empty
        // object — no command, no url, no env. Hand-written directly to a
        // real config file (not constructed in-memory) so this proves the
        // actual file-write/file-read path, not just classify()'s label.
        let malformed: [String: Any] = ["mcpServers": ["mootx01": [String: Any]()]]
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: malformed).write(to: configURL)

        try writeInstalledPlugins(home: home, plugins: [pluginID])
        let outcome = try Installer.dedupeDirectEntry(
            client: client, homeDirectory: home, workingDirectory: home, local: false
        )
        guard case .retainedForeign = outcome else {
            Issue.record("expected .retainedForeign for a malformed {} entry, got \(outcome)")
            return
        }
        let entry = try directEntry(client: client, home: home)
        #expect(entry != nil, "the malformed entry must still be present in the file after dedupe")
        #expect(entry?.isEmpty == true, "the entry must be byte-for-byte untouched (still empty)")
    }

    @Test("dedupeDirectEntry round-trip: a foreign command entry under our key survives untouched, plugin present")
    func dedupeRoundTripForeignCommandEntrySurvives() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        let client = MCPClients.supported.first { $0.id == "claude-code" }!
        let configURL = home.appendingPathComponent(client.configPath)

        // Under our key, but the command does not resolve to mootx01 at all
        // — a different tool that happens to share the server name.
        let foreign: [String: Any] = [
            "mcpServers": [
                "mootx01": [
                    "command": "/usr/bin/some-other-server",
                    "args": ["--stdio"],
                ] as [String: Any],
            ],
        ]
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: foreign).write(to: configURL)

        try writeInstalledPlugins(home: home, plugins: [pluginID])
        let outcome = try Installer.dedupeDirectEntry(
            client: client, homeDirectory: home, workingDirectory: home, local: false
        )
        guard case .retainedForeign = outcome else {
            Issue.record("expected .retainedForeign for a foreign command entry, got \(outcome)")
            return
        }
        let entry = try directEntry(client: client, home: home)
        #expect(entry?["command"] as? String == "/usr/bin/some-other-server",
                "the foreign entry must still be present, byte-for-byte untouched")
        #expect((entry?["args"] as? [String]) == ["--stdio"])
    }

    // MARK: - Four-state matrix: plugin present/absent × prior direct entry present/absent

    /// State 1: plugin absent, no prior entry — normal install wires the
    /// direct entry (the pre-existing, unchanged install path).
    @Test("state 1: no plugin, no prior entry -> normal install wires the client")
    func stateNoPluginNoPriorEntry() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        let client = MCPClients.supported.first { $0.id == "claude-code" }!

        #expect(!PluginDetector.isPluginInstalled(pluginID: pluginID, homeDirectory: home))

        try Installer.install(
            client: client, binaryPath: "/usr/local/bin/mootx01",
            daemonURL: MootPaths.residentEndpointURL,
            homeDirectory: home, workingDirectory: home, local: false
        )
        #expect(try directEntry(client: client, home: home) != nil)
    }

    /// State 2: plugin absent, prior direct entry present — normal install
    /// re-wires in place (dedupe never triggers when there is no plugin).
    @Test("state 2: no plugin, prior entry present -> normal install re-wires in place")
    func stateNoPluginPriorEntryPresent() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        let client = MCPClients.supported.first { $0.id == "claude-code" }!

        try Installer.install(
            client: client, binaryPath: "/usr/local/bin/mootx01",
            daemonURL: MootPaths.residentEndpointURL,
            homeDirectory: home, workingDirectory: home, local: false
        )
        #expect(!PluginDetector.isPluginInstalled(pluginID: pluginID, homeDirectory: home))

        // Re-run install (simulating a second `mootx01 install` with no
        // plugin yet present) — the entry survives, re-wired in place.
        try Installer.install(
            client: client, binaryPath: "/usr/local/bin/mootx01",
            daemonURL: MootPaths.residentEndpointURL,
            homeDirectory: home, workingDirectory: home, local: false
        )
        #expect(try directEntry(client: client, home: home) != nil)
    }

    /// State 3: plugin present, no prior direct entry — dedupe is a no-op
    /// (`.none`); the config gains no direct entry.
    @Test("state 3: plugin present, no prior entry -> dedupe is a no-op, no direct entry written")
    func statePluginPresentNoPriorEntry() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        let client = MCPClients.supported.first { $0.id == "claude-code" }!
        try writeInstalledPlugins(home: home, plugins: [pluginID])

        #expect(PluginDetector.isPluginInstalled(pluginID: pluginID, homeDirectory: home))
        let outcome = try Installer.dedupeDirectEntry(
            client: client, homeDirectory: home, workingDirectory: home, local: false
        )
        #expect(outcome == .none)
        #expect(try directEntry(client: client, home: home) == nil)
    }

    /// State 4: plugin present, prior direct entry present (ours, default
    /// database) — dedupe removes it so the plugin is the sole connection.
    @Test("state 4: plugin present, prior ours-default entry -> removed")
    func statePluginPresentPriorOursDefaultEntry() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        let client = MCPClients.supported.first { $0.id == "claude-code" }!

        // Prior install wrote a direct HTTP entry (ours, default database —
        // HTTP entries carry no env and cannot disagree about the database).
        try Installer.install(
            client: client, binaryPath: "/usr/local/bin/mootx01",
            daemonURL: MootPaths.residentEndpointURL,
            homeDirectory: home, workingDirectory: home, local: false
        )
        #expect(try directEntry(client: client, home: home) != nil)

        try writeInstalledPlugins(home: home, plugins: [pluginID])
        let outcome = try Installer.dedupeDirectEntry(
            client: client, homeDirectory: home, workingDirectory: home, local: false
        )
        #expect(outcome == .removedOursDefault)
        #expect(try directEntry(client: client, home: home) == nil)
    }

    // MARK: - Non-default entry survives untouched and is named

    @Test("plugin present, prior non-default (dev-rig) entry -> retained and named, never removed")
    func nonDefaultEntrySurvivesUntouched() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        let client = MCPClients.supported.first { $0.id == "claude-code" }!
        let configURL = home.appendingPathComponent(client.configPath)

        // Hand-write a dev-rig direct entry: our server name, but carrying a
        // MOOTX01_DATA_DIR override — the plugin-ownership rule's "not ours or non-default".
        let devRigEntry: [String: Any] = [
            "mcpServers": [
                "mootx01": [
                    "command": "/Users/dev/build/mootx01",
                    "args": ["proxy"],
                    "env": ["MOOTX01_DATA_DIR": "/Users/dev/rig-a/.mootx01-data"],
                ] as [String: Any],
            ],
        ]
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: devRigEntry).write(to: configURL)

        try writeInstalledPlugins(home: home, plugins: [pluginID])
        let outcome = try Installer.dedupeDirectEntry(
            client: client, homeDirectory: home, workingDirectory: home, local: false
        )
        guard case let .retainedForeign(reason, path) = outcome else {
            Issue.record("expected .retainedForeign, got \(outcome)")
            return
        }
        #expect(reason.contains("MOOTX01_DATA_DIR"))
        #expect(path == configURL.path)

        // The entry is untouched byte-for-byte in substance: still present,
        // still carrying the override.
        let entry = try directEntry(client: client, home: home)
        #expect(entry?["command"] as? String == "/Users/dev/build/mootx01")
        let env = entry?["env"] as? [String: Any]
        #expect(env?["MOOTX01_DATA_DIR"] as? String == "/Users/dev/rig-a/.mootx01-data")
    }

    /// Same guarantee on the uninstall path (plugin-owned MCP connections: uninstall must not
    /// silently remove non-default/dev entries).
    @Test("uninstall retains a non-default (dev-rig) entry and reports it")
    func uninstallRetainsNonDefaultEntry() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        let client = MCPClients.supported.first { $0.id == "claude-code" }!
        let configURL = home.appendingPathComponent(client.configPath)

        let devRigEntry: [String: Any] = [
            "mcpServers": [
                "mootx01": [
                    "command": "/Users/dev/build/mootx01",
                    "args": ["proxy"],
                    "env": ["ARIA_MCP_SQLITE_PATH": "/Users/dev/rig-a/estate.sqlite"],
                ] as [String: Any],
            ],
        ]
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: devRigEntry).write(to: configURL)

        let outcome = try Installer.uninstall(
            client: client, homeDirectory: home, workingDirectory: home, local: false
        )
        guard case let .retainedForeign(reason, path) = outcome else {
            Issue.record("expected .retainedForeign, got \(outcome)")
            return
        }
        #expect(reason.contains("ARIA_MCP_SQLITE_PATH"))
        #expect(path == configURL.path)
        #expect(try directEntry(client: client, home: home) != nil, "non-default entry must survive uninstall")
    }

    /// Uninstall still removes an ours-default entry (regression guard: the
    /// ownership check must not become a no-op for the common case).
    @Test("uninstall removes an ours-default entry as before")
    func uninstallRemovesOursDefaultEntry() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        let client = MCPClients.supported.first { $0.id == "claude-code" }!

        try Installer.install(
            client: client, binaryPath: "/usr/local/bin/mootx01",
            daemonURL: MootPaths.residentEndpointURL,
            homeDirectory: home, workingDirectory: home, local: false
        )
        let outcome = try Installer.uninstall(
            client: client, homeDirectory: home, workingDirectory: home, local: false
        )
        #expect(outcome == .removed)
        #expect(try directEntry(client: client, home: home) == nil)
    }

    // MARK: - Helpers

    private func writeInstalledPlugins(home: URL, plugins: [String]) throws {
        let path = home.appendingPathComponent(".claude/plugins/installed_plugins.json")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var pluginsObj: [String: Any] = [:]
        for id in plugins {
            pluginsObj[id] = [[
                "scope": "user",
                "installPath": "/Users/test/.claude/plugins/cache/mootx01/mootx01/1.0.15",
                "version": "1.0.15",
            ]]
        }
        let root: [String: Any] = ["version": 2, "plugins": pluginsObj]
        try JSONSerialization.data(withJSONObject: root).write(to: path)
    }

    /// Writes raw `json` text to `~/.claude/settings.json` in the sandbox —
    /// used to control `enabledPlugins` state (Adams #5). Accepts arbitrary
    /// (including deliberately malformed) text so tests can exercise the
    /// fail-closed decode path.
    private func writeSettings(home: URL, json: String) throws {
        let path = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.write(to: path, atomically: true, encoding: .utf8)
    }

    private func directEntry(client: MCPClient, home: URL) throws -> [String: Any]? {
        let configURL = home.appendingPathComponent(client.configPath)
        guard FileManager.default.fileExists(atPath: configURL.path) else { return nil }
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
        let servers = obj?[client.jsonServersKey] as? [String: Any]
        return servers?[client.serverName] as? [String: Any]
    }

    private func makeSandboxHome() throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plugin-dedupe-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func cleanupSandbox(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
