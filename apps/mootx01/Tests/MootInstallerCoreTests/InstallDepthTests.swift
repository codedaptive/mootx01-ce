// InstallDepthTests.swift
//
// Tests the integration-depth feature (§4.4): --mode parsing, the embedded
// install bundle, the per-host ceiling (plugin → skills fallback), and that
// skills/plugin payloads land where the install-map says.

import Testing
import Foundation
@testable import MootInstallerCore

@Suite("InstallDepth")
struct InstallDepthTests {

    // MARK: - --mode parsing

    @Test("InstallDepth parses the three mode flag values")
    func parsesModeFlag() {
        #expect(InstallDepth(modeFlag: "server") == .server)
        #expect(InstallDepth(modeFlag: "skills") == .skills)
        #expect(InstallDepth(modeFlag: "plugin") == .plugin)
        #expect(InstallDepth(modeFlag: "PLUGIN") == .plugin)   // case-insensitive
        #expect(InstallDepth(modeFlag: "bogus") == nil)        // unrecognised → nil
    }

    @Test("default depth is plugin (§4.4 Full Plugin)")
    func defaultIsPlugin() {
        #expect(InstallDepth.default == .plugin)
    }

    // MARK: - Embedded bundle

    @Test("embedded bundle decodes and carries the canonical skill + ten hosts")
    func bundleDecodes() {
        let b = InstallBundle.embedded
        #expect(b.skillMarkdown.contains("name: mootx01-memory"))
        // Ten matrix hosts — assert the exact set, not a bare count, so a
        // failure names the drifted host when one is added or removed.
        let expected: Set<String> = [
            "antigravity", "claude-code", "cline", "codex", "cursor",
            "gemini-cli", "github-copilot", "hermes", "opencode", "xcode",
        ]
        #expect(Set(b.hosts.keys) == expected)
        // MCP-only installer clients have no matrix row.
        #expect(b.host(forClientID: "claude-desktop") == nil)
        #expect(b.host(forClientID: "continue") == nil)
        #expect(b.host(forClientID: "kiro") == nil)
    }

    @Test("manifest-bundle hosts support plugin; module/ide hosts ceil at skills")
    func pluginCeiling() {
        let b = InstallBundle.embedded
        #expect(b.host(forClientID: "claude-code")?.supportsPlugin == true)
        #expect(b.host(forClientID: "cursor")?.supportsPlugin == true)
        #expect(b.host(forClientID: "codex")?.supportsPlugin == true)
        #expect(b.host(forClientID: "gemini-cli")?.supportsPlugin == true)
        #expect(b.host(forClientID: "antigravity")?.supportsPlugin == true)
        // §4.4 ceiling: these have no plugin format.
        #expect(b.host(forClientID: "opencode")?.supportsPlugin == false)
        #expect(b.host(forClientID: "cline")?.supportsPlugin == false)
        #expect(b.host(forClientID: "hermes")?.supportsPlugin == false)
    }

    @Test("every manifest-bundle host has an embedded package")
    func packagesPresent() {
        let b = InstallBundle.embedded
        for id in ["claude-code", "cursor", "codex", "gemini-cli", "antigravity"] {
            #expect(!b.packageFiles(forHostID: id).isEmpty, "missing package for \(id)")
        }
        // The package SKILL.md is byte-identical to the canonical skill (§0.4).
        let pkgSkill = b.packageFiles(forHostID: "claude-code")["skills/mootx01-memory/SKILL.md"]
        #expect(pkgSkill == b.skillMarkdown)
    }

    // MARK: - apply()

    @Test("server depth is a no-op for any client")
    func serverDepthNoop() throws {
        let home = sandbox()
        defer { cleanup(home) }
        let outcome = try DepthInstaller.apply(clientID: "claude-code", depth: .server, homeDirectory: home, binaryPath: "/safe/bin/mootx01")
        #expect(outcome == .server)
    }

    @Test("skills depth writes the canonical SKILL.md to the install-map path")
    func skillsDepthWritesSkill() throws {
        let home = sandbox()
        defer { cleanup(home) }
        let outcome = try DepthInstaller.apply(clientID: "claude-code", depth: .skills, homeDirectory: home, binaryPath: "/safe/bin/mootx01")
        // ~/.claude/skills/mootx01-memory/SKILL.md
        let dest = home.appendingPathComponent(".claude/skills/mootx01-memory/SKILL.md")
        guard case let .skills(path) = outcome else {
            Issue.record("expected .skills, got \(outcome)"); return
        }
        #expect(path == dest.path)
        let written = try String(contentsOf: dest, encoding: .utf8)
        #expect(written == InstallBundle.embedded.skillMarkdown)
    }

    @Test("plugin depth installs the package tree for a manifest-bundle host")
    func pluginDepthInstallsPackage() throws {
        let home = sandbox()
        defer { cleanup(home) }
        let outcome = try DepthInstaller.apply(clientID: "claude-code", depth: .plugin, homeDirectory: home, binaryPath: "/safe/bin/mootx01")
        guard case let .plugin(path) = outcome else {
            Issue.record("expected .plugin, got \(outcome)"); return
        }
        // ~/.claude/mootx01-plugin (parent of skills/).
        let root = home.appendingPathComponent(".claude/mootx01-plugin")
        #expect(path == root.path)
        // The package's SKILL.md and manifest landed.
        let skill = root.appendingPathComponent("skills/mootx01-memory/SKILL.md")
        let manifest = root.appendingPathComponent(".claude-plugin/plugin.json")
        #expect(FileManager.default.fileExists(atPath: skill.path))
        #expect(FileManager.default.fileExists(atPath: manifest.path))
        // ADR-024 §2: Claude Code's embedded package wires the resident
        // daemon's loopback HTTP endpoint, not a bare `command` placeholder
        // — there is nothing for rewriteBareMootCommand to rewrite, and
        // nothing SHOULD need the placed binary path baked in (HTTP entries
        // carry no absolute path at all).
        let mcp = root.appendingPathComponent(".mcp.json")
        let mcpContents = try String(contentsOf: mcp, encoding: .utf8)
        #expect(mcpContents.contains("\"type\" : \"http\""))
        #expect(mcpContents.contains("\"url\" : \"\(MootPaths.residentEndpointURL)\""))
        #expect(!mcpContents.contains("\"command\""))
    }

    @Test("plugin depth falls back to skills (reported) for a module-code host")
    func pluginFallsBackToSkills() throws {
        let home = sandbox()
        defer { cleanup(home) }
        let outcome = try DepthInstaller.apply(clientID: "opencode", depth: .plugin, homeDirectory: home, binaryPath: "/safe/bin/mootx01")
        guard case let .pluginFellBackToSkills(path, reason) = outcome else {
            Issue.record("expected fallback, got \(outcome)"); return
        }
        #expect(!reason.isEmpty)
        // ~/.config/opencode/skills/mootx01-memory/SKILL.md
        let dest = home.appendingPathComponent(".config/opencode/skills/mootx01-memory/SKILL.md")
        #expect(path == dest.path)
        #expect(FileManager.default.fileExists(atPath: dest.path))
    }

    @Test("MCP-only client (claude-desktop) degrades to server at any depth")
    func mcpOnlyDegradesToServer() throws {
        let home = sandbox()
        defer { cleanup(home) }
        #expect(try DepthInstaller.apply(clientID: "claude-desktop", depth: .plugin, homeDirectory: home, binaryPath: "/safe/bin/mootx01") == .server)
        #expect(try DepthInstaller.apply(clientID: "kiro", depth: .skills, homeDirectory: home, binaryPath: "/safe/bin/mootx01") == .server)
    }

    // MARK: - vault posture propagation (sec-fix 6b08d56b; ADR-024 Wave 3 Defect 2)

    /// ADR-024 Wave 3, Defect 2: an HTTP-shaped plugin entry (claude-code's
    /// `.mcp.json`, ADR-024 §2) must NOT get an env block even under
    /// vault-off — client-side env on an HTTP entry is inert (the resident
    /// daemon is the actual server, and it carries the vault posture in its
    /// own launchd environment, wired independently at daemon-registration
    /// time). Before this fix, injectVaultEnv blindly added an env key to
    /// this HTTP entry, which did nothing but looked like it had applied.
    @Test("vault-off does NOT inject env into an HTTP-shaped plugin entry (Defect 2)")
    func vaultOffSkipsHTTPShapedEntry() throws {
        let home = sandbox()
        defer { cleanup(home) }
        let outcome = try DepthInstaller.apply(
            clientID: "claude-code",
            depth: .plugin,
            homeDirectory: home,
            binaryPath: "/safe/bin/mootx01",
            vaultOff: true
        )
        guard case let .plugin(path) = outcome else {
            Issue.record("expected .plugin, got \(outcome)"); return
        }
        let root = URL(fileURLWithPath: path)

        let mcpURL = root.appendingPathComponent(".mcp.json")
        let mcpData = try Data(contentsOf: mcpURL)
        let mcp = try #require(
            try? JSONSerialization.jsonObject(with: mcpData) as? [String: Any],
            ".mcp.json must be valid JSON"
        )
        let servers = mcp["mcpServers"] as? [String: Any]
        let server = servers?["mootx01"] as? [String: Any]
        #expect(server?["command"] == nil, "claude-code's plugin entry must remain HTTP-shaped")
        #expect(server?["env"] == nil,
                "HTTP-shaped entries must never get a client-side env block — it is inert")
        #expect(server?["type"] as? String == "http")
        #expect(server?["url"] != nil)

        // Plugin-metadata JSON (no mcpServers) must not gain a spurious env key.
        let metaURL = root.appendingPathComponent(".claude-plugin/plugin.json")
        let metaData = try Data(contentsOf: metaURL)
        let meta = try #require(
            try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
            ".claude-plugin/plugin.json must be valid JSON"
        )
        #expect(meta["env"] == nil,
                "plugin-metadata JSON without mcpServers must not be patched")

        // SKILL.md must be present and unmodified.
        let skillURL = root.appendingPathComponent("skills/mootx01-memory/SKILL.md")
        #expect(FileManager.default.fileExists(atPath: skillURL.path))
    }

    /// Direct unit coverage of `injectVaultEnv`'s shape check (Defect 2): a
    /// synthetic command/stdio-shaped entry (the proxy-bridge fallback
    /// shape — dead for every host reachable through `installPlugin` today,
    /// per `rewriteBareMootCommand`'s Defect-3 audit, but the mechanism
    /// itself must still behave correctly if a host ever uses it again)
    /// still gets `MOOTX01_VAULT=0` injected; an HTTP-shaped entry does not.
    @Test("injectVaultEnv still patches a command-shaped entry; skips an HTTP-shaped one")
    func injectVaultEnvShapeCheck() {
        let commandEntry = """
        {"mcpServers":{"mootx01":{"command":"mootx01","args":["proxy"]}}}
        """
        let patched = DepthInstaller.injectVaultEnv(in: commandEntry, rel: ".mcp.json")
        let patchedObj = try? JSONSerialization.jsonObject(with: Data(patched.utf8)) as? [String: Any]
        let patchedServer = (patchedObj?["mcpServers"] as? [String: Any])?["mootx01"] as? [String: Any]
        #expect((patchedServer?["env"] as? [String: Any])?["MOOTX01_VAULT"] as? String == "0",
                "a command-shaped entry must still get MOOTX01_VAULT=0 injected")

        let httpEntry = """
        {"mcpServers":{"mootx01":{"type":"http","url":"http://127.0.0.1:4242"}}}
        """
        let unchanged = DepthInstaller.injectVaultEnv(in: httpEntry, rel: ".mcp.json")
        let unchangedObj = try? JSONSerialization.jsonObject(with: Data(unchanged.utf8)) as? [String: Any]
        let unchangedServer = (unchangedObj?["mcpServers"] as? [String: Any])?["mootx01"] as? [String: Any]
        #expect(unchangedServer?["env"] == nil, "an HTTP-shaped entry must never gain an env block")
    }

    /// vault-on (the default) must NOT inject an env block — absent MOOTX01_VAULT
    /// means vault-on per ADR-015 §1.
    @Test("vault-on (default) does not inject env block into plugin MCP configs")
    func vaultOnDoesNotInjectEnv() throws {
        let home = sandbox()
        defer { cleanup(home) }
        // Explicit vaultOff: false — same as default, but stated for clarity.
        _ = try DepthInstaller.apply(
            clientID: "claude-code",
            depth: .plugin,
            homeDirectory: home,
            binaryPath: "/safe/bin/mootx01",
            vaultOff: false
        )
        let root = home.appendingPathComponent(".claude/mootx01-plugin")
        let mcpURL = root.appendingPathComponent(".mcp.json")
        let mcpData = try Data(contentsOf: mcpURL)
        let mcp = try #require(
            try? JSONSerialization.jsonObject(with: mcpData) as? [String: Any]
        )
        let servers = mcp["mcpServers"] as? [String: Any]
        let server = servers?["mootx01"] as? [String: Any]
        #expect(server?["env"] == nil,
                "vault-on must leave env absent (absent = vault-on per ADR-015 §1)")
    }

    // MARK: - stranded cache refresh (ADR-024 Wave 3, Defect 1)

    /// Test double for `ClaudeCLIRunning`. `@unchecked Sendable` is safe here:
    /// every test using this drives it synchronously, single-threaded.
    private final class FakeClaudeCLIRunner: ClaudeCLIRunning, @unchecked Sendable {
        let shouldSucceed: Bool
        private(set) var invokedArguments: [[String]] = []
        init(shouldSucceed: Bool) { self.shouldSucceed = shouldSucceed }
        func run(arguments: [String]) -> Bool {
            invokedArguments.append(arguments)
            return shouldSucceed
        }
    }

    private func writeInstalledPlugins(home: URL, version: String = "1.0.11") throws {
        let dir = home.appendingPathComponent(".claude/plugins")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let body = """
        {"version":2,"plugins":{"mootx01@mootx01":[{"scope":"user","installPath":"cache/mootx01/mootx01/\(version)","version":"\(version)"}]}}
        """
        try body.write(to: dir.appendingPathComponent("installed_plugins.json"), atomically: true, encoding: .utf8)
    }

    @Test("stranded cache: refresh is invoked when the plugin is already installed")
    func strandedCacheRefreshInvokedWhenInstalled() throws {
        let home = sandbox()
        defer { cleanup(home) }
        try writeInstalledPlugins(home: home)

        let fake = FakeClaudeCLIRunner(shouldSucceed: true)
        DepthInstaller.refreshStrandedPluginCache(homeDirectory: home, claudeCLIRunner: fake)
        #expect(fake.invokedArguments == [["plugin", "update", "mootx01@mootx01"]])
    }

    @Test("stranded cache: refresh is a no-op when the plugin is not yet installed")
    func strandedCacheRefreshNoopWhenNotInstalled() {
        let home = sandbox()
        defer { cleanup(home) }
        let fake = FakeClaudeCLIRunner(shouldSucceed: true)
        DepthInstaller.refreshStrandedPluginCache(homeDirectory: home, claudeCLIRunner: fake)
        #expect(fake.invokedArguments.isEmpty, "no stale cache to refresh when the plugin was never installed")
    }

    @Test("stranded cache: a failing runner never fails the install (plain fallback instruction only)")
    func strandedCacheRefreshFailureDoesNotThrow() throws {
        let home = sandbox()
        defer { cleanup(home) }
        try writeInstalledPlugins(home: home)

        // shouldSucceed: false simulates both "claude CLI absent from PATH"
        // and "claude plugin update exited nonzero" — both fall back to a
        // printed instruction, never a thrown error.
        let fake = FakeClaudeCLIRunner(shouldSucceed: false)
        let outcome = try DepthInstaller.apply(
            clientID: "claude-code", depth: .plugin, homeDirectory: home,
            binaryPath: "/safe/bin/mootx01", claudeCLIRunner: fake
        )
        guard case .plugin = outcome else {
            Issue.record("expected .plugin outcome even when the cache-refresh CLI fails"); return
        }
        #expect(fake.invokedArguments == [["plugin", "update", "mootx01@mootx01"]])
    }

    @Test("stranded cache refresh is reached end-to-end through apply(), not just the standalone function")
    func strandedCacheRefreshReachedThroughApply() throws {
        let home = sandbox()
        defer { cleanup(home) }
        try writeInstalledPlugins(home: home)

        let fake = FakeClaudeCLIRunner(shouldSucceed: true)
        _ = try DepthInstaller.apply(
            clientID: "claude-code", depth: .plugin, homeDirectory: home,
            binaryPath: "/safe/bin/mootx01", claudeCLIRunner: fake
        )
        #expect(fake.invokedArguments == [["plugin", "update", "mootx01@mootx01"]])
    }

    @Test("stranded cache refresh does not fire for a client other than claude-code")
    func strandedCacheRefreshScopedToClaudeCode() throws {
        let home = sandbox()
        defer { cleanup(home) }
        try writeInstalledPlugins(home: home)  // present, but keyed for a different host's install run

        let fake = FakeClaudeCLIRunner(shouldSucceed: true)
        _ = try DepthInstaller.apply(
            clientID: "cursor", depth: .plugin, homeDirectory: home,
            binaryPath: "/safe/bin/mootx01", claudeCLIRunner: fake
        )
        #expect(fake.invokedArguments.isEmpty, "the stranded-cache refresh is Claude-Code specific")
    }

    /// Acceptance test (mission text verbatim): "a machine in today's exact
    /// broken state (marketplace dir stdio, cache pinned 1.0.11-stdio,
    /// binary upgraded) converges to HTTP-only after `mootx01 install`/
    /// `upgrade` + the plugin update hook + a Claude restart" — exercised
    /// via the injectable seam, matching the acceptance criterion's own
    /// wording.
    @Test("acceptance: a stdio-era plugin install converges to HTTP + cache refresh")
    func stdioEraInstallConvergesToHTTP() throws {
        let home = sandbox()
        defer { cleanup(home) }

        // Today's exact broken state: a stale hand-written plugin dir with a
        // bare stdio .mcp.json, AND a cache pinned to that stdio manifest.
        let pluginDir = home.appendingPathComponent(".claude/mootx01-plugin")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        try #"{"mcpServers":{"mootx01":{"command":"mootx01","args":["serve"]}}}"#
            .write(to: pluginDir.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        try writeInstalledPlugins(home: home, version: "1.0.11")

        // The exact check `mootx01 upgrade` uses before rematerializing:
        // only hosts that already have a plugin dir get rematerialized.
        let host = try #require(InstallBundle.embedded.host(forClientID: "claude-code"))
        #expect(FileManager.default.fileExists(
            atPath: DepthInstaller.pluginInstallDirectory(host: host, homeDirectory: home).path
        ))

        let fake = FakeClaudeCLIRunner(shouldSucceed: true)
        let outcome = try DepthInstaller.apply(
            clientID: "claude-code", depth: .plugin, homeDirectory: home,
            binaryPath: "/usr/local/bin/mootx01", claudeCLIRunner: fake
        )
        guard case .plugin = outcome else { Issue.record("expected .plugin outcome"); return }

        let mcpText = try String(contentsOf: pluginDir.appendingPathComponent(".mcp.json"), encoding: .utf8)
        #expect(mcpText.contains("\"type\" : \"http\""), "converged package must be HTTP-shaped")
        #expect(!mcpText.contains("\"serve\""), "stdio-era serve entry must not survive rematerialization")
        #expect(fake.invokedArguments == [["plugin", "update", "mootx01@mootx01"]],
                "the stranded cache must be refreshed as part of convergence")
    }

    // MARK: - sandbox helpers

    private func sandbox() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mootx01-depth-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
