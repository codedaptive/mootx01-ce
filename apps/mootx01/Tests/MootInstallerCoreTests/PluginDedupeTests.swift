// PluginDedupeTests.swift
//
// ADR-024 §3/§4: MCP connection ownership and install-moment dedupe.
// Covers PluginDetector.isPluginInstalled, MCPEntryClassifier.classify, and
// Installer.dedupeDirectEntry/uninstall's ownership-aware removal — the
// four-state matrix (plugin present/absent × prior direct entry present/
// absent) plus the "non-default entry survives untouched" guarantee.
//
// SAFETY: every test uses an injected sandbox home directory
// (makeSandboxHome/cleanupSandbox, same pattern as InstallerTests). Never
// point PluginDetector or Installer at the real ~/.claude or ~/.claude.json.

import Testing
import Foundation
@testable import MootInstallerCore

@Suite("Plugin dedupe (ADR-024)")
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
            "command": "/usr/local/bin/mootx01", "args": [],
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
            "command": "/usr/local/bin/mootx01", "args": [],
            "env": ["ARIA_MCP_SQLITE_PATH": "/Users/dev/estate.sqlite"],
        ]
        guard case let .foreign(reason) = MCPEntryClassifier.classify(entry: entry) else {
            Issue.record("expected .foreign")
            return
        }
        #expect(reason.contains("ARIA_MCP_SQLITE_PATH"))
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
        // MOOTX01_DATA_DIR override — ADR-024 §4's "not ours or non-default".
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

    /// Same guarantee on the uninstall path (ADR-024 §4: uninstall must not
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
