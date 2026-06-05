// InstallerTests.swift
//
// Tests for Installer: install/uninstall round-trips, idempotency,
// Continue YAML writing, and MOOT.md creation. All I/O uses sandbox
// home and working directories; no real user configs are touched.

import Testing
import Foundation
@testable import MootInstallerCore

@Suite("Installer")
struct InstallerTests {

    // MARK: - Install / uninstall round-trip (JSON clients)

    @Test("install writes mcpServers entry into non-existent config")
    func installCreatesConfig() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let client = MCPClients.supported.first { $0.id == "claude-code" }!
        let binaryPath = "/usr/local/bin/mootx01"
        let cwd = URL(fileURLWithPath: "/tmp")

        try Installer.install(
            client: client,
            binaryPath: binaryPath,
            homeDirectory: home,
            workingDirectory: cwd,
            local: false
        )

        let configURL = home.appendingPathComponent(client.configPath)
        let data = try Data(contentsOf: configURL)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let servers = obj?["mcpServers"] as? [String: Any]
        let entry = servers?[client.serverName] as? [String: Any]
        #expect(entry?["command"] as? String == binaryPath)
    }

    @Test("install into existing config merges without losing other keys")
    func installMergesExistingConfig() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let client = MCPClients.supported.first { $0.id == "claude-code" }!
        let configURL = home.appendingPathComponent(client.configPath)

        // Pre-existing config with a different server.
        let existing: [String: Any] = [
            "mcpServers": ["other-server": ["command": "/other/bin", "args": [], "env": [:] as [String: String]]]
        ]
        let existingData = try JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted])
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try existingData.write(to: configURL)

        try Installer.install(
            client: client, binaryPath: "/bin/mootx01",
            homeDirectory: home, workingDirectory: URL(fileURLWithPath: "/tmp"),
            local: false
        )

        let data = try Data(contentsOf: configURL)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let servers = obj?["mcpServers"] as? [String: Any]
        #expect(servers?["other-server"] != nil, "existing server must be preserved")
        #expect(servers?[client.serverName] != nil, "mootx01 entry must be present")
    }

    @Test("install is idempotent: second call leaves config unchanged")
    func installIdempotent() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let client = MCPClients.supported.first { $0.id == "cursor" }!
        let cwd = URL(fileURLWithPath: "/tmp")

        try Installer.install(client: client, binaryPath: "/bin/mootx01",
                              homeDirectory: home, workingDirectory: cwd, local: false)
        let configURL = home.appendingPathComponent(client.configPath)
        let firstContent = try Data(contentsOf: configURL)

        try Installer.install(client: client, binaryPath: "/bin/mootx01",
                              homeDirectory: home, workingDirectory: cwd, local: false)
        let secondContent = try Data(contentsOf: configURL)

        #expect(firstContent == secondContent)
    }

    @Test("uninstall removes only the mootx01 entry from mcpServers")
    func uninstallRemovesEntry() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let client = MCPClients.supported.first { $0.id == "claude-code" }!
        let cwd = URL(fileURLWithPath: "/tmp")

        try Installer.install(client: client, binaryPath: "/bin/mootx01",
                              homeDirectory: home, workingDirectory: cwd, local: false)
        try Installer.uninstall(client: client, homeDirectory: home, workingDirectory: cwd, local: false)

        let configURL = home.appendingPathComponent(client.configPath)
        if FileManager.default.fileExists(atPath: configURL.path) {
            let data = try Data(contentsOf: configURL)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let servers = obj?["mcpServers"] as? [String: Any] ?? [:]
            #expect(servers[client.serverName] == nil)
        }
        // If the file was removed entirely (empty mcpServers → file deleted), that's also valid.
    }

    @Test("uninstall is a no-op when config file does not exist")
    func uninstallNoOpWhenAbsent() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let client = MCPClients.supported.first { $0.id == "claude-code" }!
        // Should not throw even when the config doesn't exist.
        try Installer.uninstall(
            client: client, homeDirectory: home,
            workingDirectory: URL(fileURLWithPath: "/tmp"), local: false
        )
    }

    // MARK: - Continue YAML

    @Test("install writes a valid YAML file for Continue")
    func installContinueWritesYAML() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let client = MCPClients.supported.first { $0.id == "continue" }!
        let binaryPath = "/usr/local/bin/mootx01"

        try Installer.install(
            client: client, binaryPath: binaryPath,
            homeDirectory: home, workingDirectory: URL(fileURLWithPath: "/tmp"),
            local: false
        )

        let configURL = home.appendingPathComponent(client.configPath)
        let content = try String(contentsOf: configURL, encoding: .utf8)
        #expect(content.contains("command:"))
        #expect(content.contains(binaryPath))
    }

    // MARK: - Claude Code --local mode

    @Test("install in local mode writes to .mcp.json in workingDirectory")
    func installLocalModeCaudeCode() throws {
        let home = try makeSandboxHome()
        let cwd = try makeSandboxHome()
        defer { cleanupSandbox(home); cleanupSandbox(cwd) }

        let client = MCPClients.supported.first { $0.id == "claude-code" }!
        try Installer.install(
            client: client, binaryPath: "/bin/mootx01",
            homeDirectory: home, workingDirectory: cwd, local: true
        )

        let localConfig = cwd.appendingPathComponent(".mcp.json")
        #expect(FileManager.default.fileExists(atPath: localConfig.path))
    }

    // MARK: - MOOT.md

    @Test("writeMOOTmd creates MOOT.md when absent")
    func writeMOOTmdCreatesFile() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        try Installer.writeMOOTmd(
            homeDirectory: home, local: false,
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )

        let mootmd = home.appendingPathComponent(".claude/MOOT.md")
        #expect(FileManager.default.fileExists(atPath: mootmd.path))
    }

    @Test("writeMOOTmd does not overwrite existing MOOT.md")
    func writeMOOTmdSkipsExisting() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let dir = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mootmd = dir.appendingPathComponent("MOOT.md")
        try "custom content".write(to: mootmd, atomically: true, encoding: .utf8)

        try Installer.writeMOOTmd(
            homeDirectory: home, local: false,
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )

        let content = try String(contentsOf: mootmd, encoding: .utf8)
        #expect(content == "custom content")
    }

    // MARK: - Helpers

    private func makeSandboxHome() throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("installer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func cleanupSandbox(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
