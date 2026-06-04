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
            "/Users/test/Library/Application Support/MOOTx01"
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
            "/Users/test/Library/Application Support/MOOTx01"
        )
    }

    func testEstateURLAppendsFixedFilename() {
        let dir = URL(fileURLWithPath: "/Users/test/Library/Application Support/MOOTx01", isDirectory: true)
        let estate = MootPaths.estateURL(in: dir)
        XCTAssertEqual(
            estate.path,
            "/Users/test/Library/Application Support/MOOTx01/estate.sqlite"
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
}
