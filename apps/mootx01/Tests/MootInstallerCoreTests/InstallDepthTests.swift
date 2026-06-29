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
