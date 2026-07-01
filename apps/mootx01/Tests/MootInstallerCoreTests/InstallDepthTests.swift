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

    @Test("embedded bundle decodes and carries the canonical skill + nine hosts")
    func bundleDecodes() {
        let b = InstallBundle.embedded
        #expect(b.skillMarkdown.contains("name: mootx01-memory"))
        // Nine matrix hosts.
        #expect(b.hosts.count == 9)
        #expect(b.host(forClientID: "claude-code") != nil)
        #expect(b.host(forClientID: "antigravity") != nil)
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
        let mcp = root.appendingPathComponent(".mcp.json")
        let mcpContents = try String(contentsOf: mcp, encoding: .utf8)
        #expect(mcpContents.contains("\"command\" : \"/safe/bin/mootx01\""))
        #expect(!mcpContents.contains("\"command\" : \"mootx01\""))
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

    // MARK: - vault posture propagation (sec-fix 6b08d56b)

    /// vault-off must write MOOTX01_VAULT=0 into the env block of every MCP
    /// config JSON in the installed plugin package. Skills files (SKILL.md) and
    /// plugin-metadata JSON files (no mcpServers key) must be unmodified.
    @Test("vault-off injects MOOTX01_VAULT=0 into plugin MCP config files")
    func vaultOffInjectsEnvIntoMCPConfigs() throws {
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

        // The .mcp.json in the plugin package must carry MOOTX01_VAULT=0.
        let mcpURL = root.appendingPathComponent(".mcp.json")
        let mcpData = try Data(contentsOf: mcpURL)
        let mcp = try #require(
            try? JSONSerialization.jsonObject(with: mcpData) as? [String: Any],
            ".mcp.json must be valid JSON after vault-off injection"
        )
        let servers = mcp["mcpServers"] as? [String: Any]
        let server = servers?["mootx01"] as? [String: Any]
        let env = server?["env"] as? [String: Any]
        #expect(env?["MOOTX01_VAULT"] as? String == "0",
                "vault-off must write MOOTX01_VAULT=0 into .mcp.json env block")

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
