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

    // MARK: - Binary placement

    @Test("placeBinary copies the binary to ~/.mootx01/bin/mootx01 and makes it executable")
    func placeBinaryCopiesAndChmods() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let source = try makeFakeBinary()
        defer { try? FileManager.default.removeItem(at: source) }

        let placed = try Installer.placeBinary(sourcePath: source.path, homeDirectory: home)

        let expected = home.appendingPathComponent(".mootx01/bin/mootx01")
        #expect(placed == expected.path, "placeBinary must return the installed absolute path")
        #expect(FileManager.default.fileExists(atPath: expected.path))

        // Executable bit (0755) must be set.
        let attrs = try FileManager.default.attributesOfItem(atPath: expected.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(perms & 0o111 != 0, "placed binary must be executable")
    }

    @Test("placeBinary creates a PATH symlink that resolves to the placed binary")
    func placeBinaryCreatesResolvingSymlink() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let source = try makeFakeBinary()
        defer { try? FileManager.default.removeItem(at: source) }

        let placed = try Installer.placeBinary(sourcePath: source.path, homeDirectory: home)

        let symlink = home.appendingPathComponent(".local/bin/mootx01")
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path)
        #expect(dest == placed, "symlink must resolve to the placed binary")
    }

    @Test("placeBinary overwrites an existing install (re-install is safe)")
    func placeBinaryReinstallOverwrites() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let first = try makeFakeBinary(contents: "v1")
        defer { try? FileManager.default.removeItem(at: first) }
        _ = try Installer.placeBinary(sourcePath: first.path, homeDirectory: home)

        let second = try makeFakeBinary(contents: "v2")
        defer { try? FileManager.default.removeItem(at: second) }
        let placed = try Installer.placeBinary(sourcePath: second.path, homeDirectory: home)

        let content = try String(contentsOfFile: placed, encoding: .utf8)
        #expect(content == "v2", "re-install must overwrite the prior binary")
    }

    @Test("placeBinary re-run from the installed binary does not create a self-symlink loop")
    func placeBinaryReinstallFromPlacedBinaryDoesNotLoop() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let source = try makeFakeBinary(contents: "real")
        defer { try? FileManager.default.removeItem(at: source) }
        let placed = try Installer.placeBinary(sourcePath: source.path, homeDirectory: home)

        let fm = FileManager.default
        let symlink = home.appendingPathComponent(".local/bin/mootx01").path

        // Regression: `mootx01 install` run from the installed binary arrives
        // here with sourcePath = the ~/.local/bin/mootx01 symlink (or the
        // resolved installed path). Previously copyItem copied the LINK and,
        // after removing dest, produced a self-referential symlink (ELOOP)
        // that broke every subsequent install.
        _ = try Installer.placeBinary(sourcePath: symlink, homeDirectory: home)
        _ = try Installer.placeBinary(sourcePath: placed, homeDirectory: home)

        // Dest must stay a REGULAR FILE — never a symlink, let alone a loop.
        #expect((try? fm.destinationOfSymbolicLink(atPath: placed)) == nil,
                "placed binary must remain a regular file, not a symlink")
        #expect(fm.fileExists(atPath: placed), "placed binary must still exist")
        #expect(try String(contentsOfFile: placed, encoding: .utf8) == "real",
                "the real binary content must survive re-install from itself")
        #expect(try fm.destinationOfSymbolicLink(atPath: symlink) == placed,
                "PATH symlink still resolves to the real placed binary")
    }

    @Test("config command is the ABSOLUTE placed path, not the source path")
    func configCommandUsesPlacedPath() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        // Simulate the InstallCommand flow: place, then write configs with
        // the placed path. The source lives somewhere unrelated (a CWD/dev
        // dir stand-in); the config must NOT reference it.
        let source = try makeFakeBinary()
        defer { try? FileManager.default.removeItem(at: source) }
        let placed = try Installer.placeBinary(sourcePath: source.path, homeDirectory: home)

        let client = MCPClients.supported.first { $0.id == "claude-code" }!
        try Installer.install(
            client: client, binaryPath: placed,
            homeDirectory: home, workingDirectory: URL(fileURLWithPath: "/tmp"), local: false
        )

        let configURL = home.appendingPathComponent(client.configPath)
        let data = try Data(contentsOf: configURL)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let servers = obj?["mcpServers"] as? [String: Any]
        let entry = servers?[client.serverName] as? [String: Any]
        let command = entry?["command"] as? String

        #expect(command == home.appendingPathComponent(".mootx01/bin/mootx01").path,
                "config command must be the absolute placed path")
        #expect(command?.hasPrefix("/") == true, "config command must be absolute")
        #expect(command != source.path, "config command must not be the source/CWD path")
        #expect(command?.hasPrefix("./") == false, "config command must not be relative")
        let args = entry?["args"] as? [String]
        #expect(args?.isEmpty == true, "args must stay empty")
    }

    @Test("removePlacedBinary removes the binary and the PATH symlink")
    func removePlacedBinaryCleansUp() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }

        let source = try makeFakeBinary()
        defer { try? FileManager.default.removeItem(at: source) }
        _ = try Installer.placeBinary(sourcePath: source.path, homeDirectory: home)

        try Installer.removePlacedBinary(homeDirectory: home)

        let placed = home.appendingPathComponent(".mootx01/bin/mootx01")
        let symlink = home.appendingPathComponent(".local/bin/mootx01")
        let installRoot = home.appendingPathComponent(".mootx01")
        #expect(!FileManager.default.fileExists(atPath: placed.path))
        #expect(!FileManager.default.fileExists(atPath: installRoot.path), "install root removed")
        // lstat-aware check: the symlink (dangling or not) must be gone.
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: symlink.path)) == nil)
        #expect(!FileManager.default.fileExists(atPath: symlink.path))
    }

    @Test("removePlacedBinary is a no-op when nothing was installed")
    func removePlacedBinaryNoOp() throws {
        let home = try makeSandboxHome()
        defer { cleanupSandbox(home) }
        // Must not throw on a clean home.
        try Installer.removePlacedBinary(homeDirectory: home)
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

    /// Create a throwaway file that stands in for the `mootx01` binary
    /// in placement tests. Written to a temp dir distinct from any
    /// sandbox home so tests can assert the config path is NOT the
    /// source path.
    private func makeFakeBinary(contents: String = "#!/bin/sh\nexit 0\n") throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fake-mootx01-\(UUID().uuidString)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
