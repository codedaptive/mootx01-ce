// UpgradeReconciliationTests.swift
//
// Regression coverage for MO-01: upgrade-time reconciliation must respect
// ownership and recorded user intent.
//
// Finding #10 — `Installer.cleanupRedundantCodexDirectEntry` removes the
// direct `[mcp_servers.mootx01]` entry from ~/.codex/config.toml ONLY when
// the plugin owns the connection AND the entry classifies `.oursDefault`
// via MCPEntryClassifier. Entries the installer does not own (foreign
// shape) or that are scoped elsewhere (env override, `--db` args,
// non-default-port URL, unparseable table) survive untouched.
//
// Finding #2 — `DepthInstaller.apply(depth: .plugin,
// preserveRecordedPluginDisable: true)` (the upgrade posture) preserves an
// EXPLICIT `enabledPlugins["mootx01@mootx01"] = false` recorded in
// ~/.claude/settings.json, while an absent entry still enables (no
// recorded decision), and the install posture (default parameter) keeps
// today's enable-on-register behavior.
//
// SAFETY: every test uses an injected sandbox home directory
// (makeSandboxHome/cleanupSandbox, same pattern as PluginDedupeTests).
// Never point these APIs at the real ~/.claude or ~/.codex.

import Testing
import Foundation
@testable import MootInstallerCore

@Suite("Upgrade reconciliation — ownership and recorded intent")
struct UpgradeReconciliationTests {

    private let pluginID = "mootx01@mootx01"

    // MARK: - Finding #10: Codex direct-entry cleanup ownership gate

    @Test("an entry not shaped like ours (unowned) survives cleanup")
    func foreignShapedEntrySurvives() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        try makeCodexPluginOwner(home: home, table: """
            [mcp_servers.mootx01]
            command = "/usr/local/bin/somebody-elses-server"
            args = ["serve"]
            """)
        let before = try codexConfigText(home: home)

        let outcome = Installer.cleanupRedundantCodexDirectEntry(homeDirectory: home)

        guard case .retainedForeign = outcome else {
            Issue.record("expected .retainedForeign, got \(outcome)"); return
        }
        #expect(try codexConfigText(home: home) == before,
                "a foreign-shaped entry must survive cleanup byte-identically")
        #expect(!FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".codex/config.toml.mootx01-backup").path),
                "no backup may be written when nothing is removed")
    }

    @Test("an entry scoped via a --db args override survives cleanup")
    func dbArgsScopedEntrySurvives() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        try makeCodexPluginOwner(home: home, table: """
            [mcp_servers.mootx01]
            command = "/Users/dev/.mootx01/bin/mootx01"
            args = ["serve", "--db", "work"]
            """)
        let before = try codexConfigText(home: home)

        let outcome = Installer.cleanupRedundantCodexDirectEntry(homeDirectory: home)

        guard case let .retainedForeign(reason) = outcome else {
            Issue.record("expected .retainedForeign, got \(outcome)"); return
        }
        #expect(reason.contains("--db"))
        #expect(try codexConfigText(home: home) == before)
    }

    @Test("an entry scoped via an equals-form --db=<name> override survives cleanup")
    func dbEqualsFormScopedEntrySurvives() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        // ArgumentParser accepts both `--db work` and `--db=work`; the
        // classifier must treat both as an estate override (Adams MO-01
        // INFO-1 — the equals form previously slipped past the exact-match
        // check on BOTH the JSON and TOML paths).
        try makeCodexPluginOwner(home: home, table: """
            [mcp_servers.mootx01]
            command = "/Users/dev/.mootx01/bin/mootx01"
            args = ["serve", "--db=work"]
            """)
        let before = try codexConfigText(home: home)

        let outcome = Installer.cleanupRedundantCodexDirectEntry(homeDirectory: home)

        guard case let .retainedForeign(reason) = outcome else {
            Issue.record("expected .retainedForeign, got \(outcome)"); return
        }
        #expect(reason.contains("--db"))
        #expect(try codexConfigText(home: home) == before)
    }

    @Test("an env child table selects no estate; a redundant entry carrying one is still removed")
    func envChildTableDoesNotProtectEntry() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        try makeCodexPluginOwner(home: home, table: """
            [mcp_servers.mootx01]
            command = "/Users/dev/.mootx01/bin/mootx01"
            args = ["serve"]

            [mcp_servers.mootx01.env]
            MOOTX01_HTTP_PORT = "4242"
            """)

        let outcome = Installer.cleanupRedundantCodexDirectEntry(homeDirectory: home)

        if case .retainedForeign = outcome {
            Issue.record("an env table must not protect a default-estate entry; got \(outcome)")
        }
        #expect(!(try codexConfigText(home: home)).contains("[mcp_servers.mootx01]"))
    }

    @Test("a non-default-port URL entry survives cleanup")
    func nonDefaultPortURLEntrySurvives() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        try makeCodexPluginOwner(home: home, table: """
            [mcp_servers.mootx01]
            url = "http://127.0.0.1:9999"
            """)
        let before = try codexConfigText(home: home)

        let outcome = Installer.cleanupRedundantCodexDirectEntry(homeDirectory: home)

        guard case .retainedForeign = outcome else {
            Issue.record("expected .retainedForeign, got \(outcome)"); return
        }
        #expect(try codexConfigText(home: home) == before,
                "a deliberately-scoped daemon endpoint must never be auto-removed")
    }

    @Test("a table that cannot be parsed is retained, never removed")
    func unparseableEntrySurvives() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        try makeCodexPluginOwner(home: home, table: """
            [mcp_servers.mootx01]
            command = \"\"\"multi
            line\"\"\"
            """)
        let before = try codexConfigText(home: home)

        let outcome = Installer.cleanupRedundantCodexDirectEntry(homeDirectory: home)

        guard case let .retainedForeign(reason) = outcome else {
            Issue.record("expected .retainedForeign, got \(outcome)"); return
        }
        #expect(reason.contains("could not be parsed"))
        #expect(try codexConfigText(home: home) == before,
                "parse failure must fail toward leaving configuration alone")
    }

    @Test("control: the installer's own default HTTP entry IS removed, with backup")
    func oursDefaultHTTPEntryIsRemoved() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        try makeCodexPluginOwner(home: home, table: """
            [mcp_servers.mootx01]
            url = "http://127.0.0.1:\(MootPaths.defaultResidentPort)"
            """)
        let before = try codexConfigText(home: home)

        let outcome = Installer.cleanupRedundantCodexDirectEntry(homeDirectory: home)

        #expect(outcome == .removed,
                "normal reconciliation must still collapse a redundant default entry")
        let after = try codexConfigText(home: home)
        #expect(!after.contains("[mcp_servers.mootx01]"),
                "the redundant table must be gone")
        #expect(after.contains("[plugins."),
                "unrelated tables must be preserved")
        let backup = home.appendingPathComponent(".codex/config.toml.mootx01-backup")
        #expect(try String(contentsOf: backup, encoding: .utf8) == before,
                "the backup must carry the pre-removal file")
    }

    @Test("control: the installer's own default stdio entry IS removed")
    func oursDefaultStdioEntryIsRemoved() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        // The exact shape mergeIntoTOMLConfig writes for directStdio: binary
        // path ending in mootx01, serve args, MOOTX01_HTTP_PORT env (not an
        // override key).
        try makeCodexPluginOwner(home: home, table: """
            [mcp_servers.mootx01]
            command = "/Users/dev/.mootx01/bin/mootx01"
            args = ["serve"]
            env = { MOOTX01_HTTP_PORT = "" }
            """)

        let outcome = Installer.cleanupRedundantCodexDirectEntry(homeDirectory: home)

        #expect(outcome == .removed)
        #expect(try !codexConfigText(home: home).contains("[mcp_servers.mootx01]"))
    }

    @Test("a disabled or uninstalled plugin never triggers cleanup")
    func pluginNotOwnerLeavesEntry() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        // Plugin registered but enabled = false — the direct entry may be
        // the client's ONLY working connection.
        try writeCodexConfig(home: home, text: """
            [plugins."mootx01@mootx01"]
            enabled = false

            [mcp_servers.mootx01]
            url = "http://127.0.0.1:\(MootPaths.defaultResidentPort)"
            """)
        try writeCodexPluginCache(home: home)
        let before = try codexConfigText(home: home)

        let outcome = Installer.cleanupRedundantCodexDirectEntry(homeDirectory: home)

        #expect(outcome == .pluginNotOwner)
        #expect(try codexConfigText(home: home) == before)
    }

    // MARK: - Finding #2: recorded plugin-disable survives upgrade

    @Test("an explicitly disabled plugin stays disabled across an upgrade-shaped apply")
    func recordedDisableSurvivesUpgrade() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        try writeSettings(home: home, json: #"{"enabledPlugins":{"mootx01@mootx01":false}}"#)
        let fake = FakeClaudeCLIRunner()

        let outcome = try DepthInstaller.apply(
            clientID: "claude-code", depth: .plugin, homeDirectory: home,
            binaryPath: "/safe/bin/mootx01",
            preserveRecordedPluginDisable: true,
            claudeCLIRunner: fake)

        guard case .plugin = outcome else {
            Issue.record("expected .plugin outcome, got \(outcome)"); return
        }
        let settings = try readSettings(home: home)
        let enabled = settings["enabledPlugins"] as? [String: Any]
        #expect(enabled?[pluginID] as? Bool == false,
                "an upgrade must never override a recorded user disable")
        #expect(settings["extraKnownMarketplaces"] != nil,
                "the marketplace registration must still refresh so the package stays current")
    }

    @Test("control: with no recorded decision, upgrade-shaped apply still enables")
    func absentDecisionStillEnablesOnUpgrade() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        try writeSettings(home: home, json: #"{"enabledPlugins":{}}"#)
        let fake = FakeClaudeCLIRunner()

        _ = try DepthInstaller.apply(
            clientID: "claude-code", depth: .plugin, homeDirectory: home,
            binaryPath: "/safe/bin/mootx01",
            preserveRecordedPluginDisable: true,
            claudeCLIRunner: fake)

        let enabled = try readSettings(home: home)["enabledPlugins"] as? [String: Any]
        #expect(enabled?[pluginID] as? Bool == true,
                "an absent entry is not a recorded decision; default enable applies")
    }

    @Test("control: install posture (default parameter) keeps enable-on-register")
    func installPostureStillEnables() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        try writeSettings(home: home, json: #"{"enabledPlugins":{"mootx01@mootx01":false}}"#)
        let fake = FakeClaudeCLIRunner()

        // No preserveRecordedPluginDisable argument: mootx01 install's
        // posture — an explicit install run re-enables.
        _ = try DepthInstaller.apply(
            clientID: "claude-code", depth: .plugin, homeDirectory: home,
            binaryPath: "/safe/bin/mootx01",
            claudeCLIRunner: fake)

        let enabled = try readSettings(home: home)["enabledPlugins"] as? [String: Any]
        #expect(enabled?[pluginID] as? Bool == true,
                "explicit install is itself the user's decision to activate the plugin")
    }

    // MARK: - Fixtures

    /// Writes a Codex config carrying an enabled plugin registration plus
    /// `table` (the `[mcp_servers.mootx01]` variant under test), and the
    /// plugin cache directory — together satisfying
    /// `PluginDetector.ownsCodexConnection`.
    private func makeCodexPluginOwner(home: URL, table: String) throws {
        try writeCodexConfig(home: home, text: """
            [plugins."mootx01@mootx01"]
            enabled = true

            \(table)
            """)
        try writeCodexPluginCache(home: home)
    }

    private func writeCodexConfig(home: URL, text: String) throws {
        let url = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeCodexPluginCache(home: URL) throws {
        let manifestDir = home.appendingPathComponent(
            ".codex/plugins/cache/mootx01/mootx01/1.0.15/.codex-plugin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: manifestDir, withIntermediateDirectories: true)
        try #"{"name":"mootx01","version":"1.0.15"}"#.write(
            to: manifestDir.appendingPathComponent("plugin.json"),
            atomically: true, encoding: .utf8)
    }

    private func codexConfigText(home: URL) throws -> String {
        try String(contentsOf: home.appendingPathComponent(".codex/config.toml"),
                   encoding: .utf8)
    }

    private func writeSettings(home: URL, json: String) throws {
        let path = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.write(to: path, atomically: true, encoding: .utf8)
    }

    private func readSettings(home: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: home.appendingPathComponent(".claude/settings.json"))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private final class FakeClaudeCLIRunner: ClaudeCLIRunning, @unchecked Sendable {
        func run(arguments: [String]) -> Bool { true }
    }

    private func makeSandboxHome() throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("upgrade-reconciliation-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func cleanupSandbox(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
