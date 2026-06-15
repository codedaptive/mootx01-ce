// PathsTests.swift
//
// Pure path-math tests for MootInstallerCore.MootPaths. No
// filesystem touching; the tests inject environment and home so
// they run identically under any user.

import XCTest
@testable import MootInstallerCore

final class PathsTests: XCTestCase {

    func testResolveDataDirectoryDefaultsToApplicationSupport() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let resolved = MootPaths.resolveDataDirectory(
            environment: [:],
            homeDirectory: home
        )
        XCTAssertEqual(
            resolved.path,
            "/Users/test/Library/Application Support/com.mootx01.ce"
        )
    }

    func testResolveDataDirectoryHonorsEnvironmentOverride() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let resolved = MootPaths.resolveDataDirectory(
            environment: ["MOOTX01_DATA_DIR": "/tmp/sandbox-moot"],
            homeDirectory: home
        )
        XCTAssertEqual(resolved.path, "/tmp/sandbox-moot")
    }

    func testResolveDataDirectoryIgnoresEmptyOverride() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let resolved = MootPaths.resolveDataDirectory(
            environment: ["MOOTX01_DATA_DIR": ""],
            homeDirectory: home
        )
        XCTAssertEqual(
            resolved.path,
            "/Users/test/Library/Application Support/com.mootx01.ce"
        )
    }

    func testEstateURLAppendsFixedFilename() {
        let dir = URL(fileURLWithPath: "/Users/test/Library/Application Support/com.mootx01.ce", isDirectory: true)
        let estate = MootPaths.estateURL(in: dir)
        XCTAssertEqual(
            estate.path,
            "/Users/test/Library/Application Support/com.mootx01.ce/estate.sqlite"
        )
    }

    func testDefaultOwnerIdentifierIsNonEmpty() {
        // LocusKit.Estate.create rejects an empty owner identifier
        // up front; the default the installer stamps must satisfy
        // that precondition.
        XCTAssertFalse(MootPaths.defaultOwnerIdentifier.isEmpty)
    }

    func testLocalMCPConfigURLAppendsFixedFilename() {
        // localMCPConfigURL must return workingDirectory/.mcp.json —
        // the file Claude Code reads for project-scoped MCP servers.
        let workdir = URL(fileURLWithPath: "/Users/test/myproject", isDirectory: true)
        let configURL = MootPaths.localMCPConfigURL(workingDirectory: workdir)
        XCTAssertEqual(configURL.path, "/Users/test/myproject/.mcp.json")
    }

    func testGlobalClaudeSettingsURLIsUnderDotClaude() {
        // globalClaudeSettingsURL must return homeDirectory/.claude/settings.json —
        // the file Claude Code uses for global permissions.allow entries.
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let settingsURL = MootPaths.globalClaudeSettingsURL(homeDirectory: home)
        XCTAssertEqual(settingsURL.path, "/Users/test/.claude/settings.json")
    }

    func testLocalClaudeSettingsURLIsUnderDotClaude() {
        // localClaudeSettingsURL must return workingDirectory/.claude/settings.json —
        // the per-project settings file that receives ARIA tool approvals when
        // --local is used.
        let workdir = URL(fileURLWithPath: "/Users/test/myproject", isDirectory: true)
        let settingsURL = MootPaths.localClaudeSettingsURL(workingDirectory: workdir)
        XCTAssertEqual(settingsURL.path, "/Users/test/myproject/.claude/settings.json")
    }

    func testInstalledBinaryURLIsUnderDotMootx01Bin() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        XCTAssertEqual(
            MootPaths.installedBinaryURL(homeDirectory: home).path,
            "/Users/test/.mootx01/bin/mootx01"
        )
    }

    func testInstalledBinaryDirURLIsUnderDotMootx01() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        XCTAssertEqual(
            MootPaths.installedBinaryDirURL(homeDirectory: home).path,
            "/Users/test/.mootx01/bin"
        )
    }

    func testBinarySymlinkURLIsUnderLocalBin() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        XCTAssertEqual(
            MootPaths.binarySymlinkURL(homeDirectory: home).path,
            "/Users/test/.local/bin/mootx01"
        )
    }

    func testLocalBinDirURLIsUnderLocal() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        XCTAssertEqual(
            MootPaths.localBinDirURL(homeDirectory: home).path,
            "/Users/test/.local/bin"
        )
    }

    func testGlobalAndLocalClaudeSettingsURLShareFilename() {
        // Both helpers must agree on the filename component so that code
        // choosing between global and local settings targets is consistent.
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let workdir = URL(fileURLWithPath: "/Users/test/myproject", isDirectory: true)
        XCTAssertEqual(
            MootPaths.globalClaudeSettingsURL(homeDirectory: home).lastPathComponent,
            MootPaths.localClaudeSettingsURL(workingDirectory: workdir).lastPathComponent
        )
    }

    func testDaemonPortFileURLAppendsFixedFilename() {
        // daemonPortFileURL must return <dataDir>/daemon.port — the same
        // filename the resident daemon writes and daemon_client::resolved_port
        // reads in the Rust vertical.
        let dataDir = URL(fileURLWithPath: "/Users/test/Library/Application Support/com.mootx01.ce", isDirectory: true)
        let portFileURL = MootPaths.daemonPortFileURL(in: dataDir)
        XCTAssertEqual(portFileURL.path,
            "/Users/test/Library/Application Support/com.mootx01.ce/daemon.port")
    }

    func testResolvedResidentPortReturnsFallbackWhenFileAbsent() {
        // resolvedResidentPort must return defaultResidentPort (4242) when
        // daemon.port does not exist — mirrors daemon_client::resolved_port fallback.
        let dataDir = URL(fileURLWithPath: "/tmp/mootx01-test-no-port-file-\(Int.random(in: 1000...9999))", isDirectory: true)
        let port = MootPaths.resolvedResidentPort(dataDir: dataDir)
        XCTAssertEqual(port, MootPaths.defaultResidentPort) // 4242
    }

    func testResolvedResidentPortReadsPortFromFile() {
        // resolvedResidentPort must return the port written in daemon.port when
        // the file is present and valid — mirrors daemon_client::resolved_port
        // port-file-first resolution.
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mootx01-test-port-\(Int.random(in: 1000...9999))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let portFileURL = MootPaths.daemonPortFileURL(in: dataDir)
        try? "5050\n".write(to: portFileURL, atomically: true, encoding: .utf8)

        let port = MootPaths.resolvedResidentPort(dataDir: dataDir)
        XCTAssertEqual(port, 5050)
    }
}
