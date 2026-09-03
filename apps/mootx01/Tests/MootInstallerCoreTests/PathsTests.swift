// PathsTests.swift
//
// Tests for MootInstallerCore.MootPaths. Most tests are pure path math
// (environment and home injected, no filesystem access). Daemon-port
// tests write a temporary daemon.port file to exercise
// MootPaths.resolvedResidentPort(dataDir:) end to end. Each
// filesystem-touching test uses its own uniquely-named temp directory,
// so the suite is safe under swift-testing's parallel execution.

import Foundation
import Testing
@testable import MootInstallerCore

@Suite("MootPaths")
struct PathsTests {

    @Test func resolveDataDirectoryDefaultsToApplicationSupport() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let resolved = MootPaths.resolveDataDirectory(
            environment: [:],
            homeDirectory: home
        )
        #expect(
            resolved.path ==
            "/Users/test/Library/Application Support/com.mootx01.ce"
        )
    }

    @Test func resolveDataDirectoryHonorsEnvironmentOverride() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let resolved = MootPaths.resolveDataDirectory(
            environment: ["MOOTX01_DATA_DIR": "/tmp/sandbox-moot"],
            homeDirectory: home
        )
        #expect(resolved.path == "/tmp/sandbox-moot")
    }

    @Test func resolveDataDirectoryIgnoresEmptyOverride() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let resolved = MootPaths.resolveDataDirectory(
            environment: ["MOOTX01_DATA_DIR": ""],
            homeDirectory: home
        )
        #expect(
            resolved.path ==
            "/Users/test/Library/Application Support/com.mootx01.ce"
        )
    }

    @Test func estateURLAppendsFixedFilename() {
        let dir = URL(fileURLWithPath: "/Users/test/Library/Application Support/com.mootx01.ce", isDirectory: true)
        let estate = MootPaths.estateURL(in: dir)
        #expect(
            estate.path ==
            "/Users/test/Library/Application Support/com.mootx01.ce/estate.sqlite"
        )
    }

    @Test func defaultOwnerIdentifierIsNonEmpty() {
        // LocusKit.Estate.create rejects an empty owner identifier
        // up front; the default the installer stamps must satisfy
        // that precondition.
        #expect(!MootPaths.defaultOwnerIdentifier.isEmpty)
    }

    @Test func localMCPConfigURLAppendsFixedFilename() {
        // localMCPConfigURL must return workingDirectory/.mcp.json —
        // the file Claude Code reads for project-scoped MCP servers.
        let workdir = URL(fileURLWithPath: "/Users/test/myproject", isDirectory: true)
        let configURL = MootPaths.localMCPConfigURL(workingDirectory: workdir)
        #expect(configURL.path == "/Users/test/myproject/.mcp.json")
    }

    @Test func globalClaudeSettingsURLIsUnderDotClaude() {
        // globalClaudeSettingsURL must return homeDirectory/.claude/settings.json —
        // the file Claude Code uses for global permissions.allow entries.
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let settingsURL = MootPaths.globalClaudeSettingsURL(homeDirectory: home)
        #expect(settingsURL.path == "/Users/test/.claude/settings.json")
    }

    @Test func localClaudeSettingsURLIsUnderDotClaude() {
        // localClaudeSettingsURL must return workingDirectory/.claude/settings.json —
        // the per-project settings file that receives ARIA tool approvals when
        // --local is used.
        let workdir = URL(fileURLWithPath: "/Users/test/myproject", isDirectory: true)
        let settingsURL = MootPaths.localClaudeSettingsURL(workingDirectory: workdir)
        #expect(settingsURL.path == "/Users/test/myproject/.claude/settings.json")
    }

    @Test func installedBinaryURLIsUnderDotMootx01Bin() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        #expect(
            MootPaths.installedBinaryURL(homeDirectory: home).path ==
            "/Users/test/.mootx01/bin/mootx01"
        )
    }

    @Test func installedBinaryDirURLIsUnderDotMootx01() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        #expect(
            MootPaths.installedBinaryDirURL(homeDirectory: home).path ==
            "/Users/test/.mootx01/bin"
        )
    }

    @Test func binarySymlinkURLIsUnderLocalBin() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        #expect(
            MootPaths.binarySymlinkURL(homeDirectory: home).path ==
            "/Users/test/.local/bin/mootx01"
        )
    }

    @Test func localBinDirURLIsUnderLocal() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        #expect(
            MootPaths.localBinDirURL(homeDirectory: home).path ==
            "/Users/test/.local/bin"
        )
    }

    @Test func globalAndLocalClaudeSettingsURLShareFilename() {
        // Both helpers must agree on the filename component so that code
        // choosing between global and local settings targets is consistent.
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let workdir = URL(fileURLWithPath: "/Users/test/myproject", isDirectory: true)
        #expect(
            MootPaths.globalClaudeSettingsURL(homeDirectory: home).lastPathComponent ==
            MootPaths.localClaudeSettingsURL(workingDirectory: workdir).lastPathComponent
        )
    }

    @Test func daemonPortFileURLAppendsFixedFilename() {
        // daemonPortFileURL must return <dataDir>/daemon.port — the same
        // filename the resident daemon writes and daemon_client::resolved_port
        // reads in the Rust vertical.
        let dataDir = URL(fileURLWithPath: "/Users/test/Library/Application Support/com.mootx01.ce", isDirectory: true)
        let portFileURL = MootPaths.daemonPortFileURL(in: dataDir)
        #expect(
            portFileURL.path ==
            "/Users/test/Library/Application Support/com.mootx01.ce/daemon.port"
        )
    }

    @Test func resolvedResidentPortReturnsFallbackWhenFileAbsent() {
        // resolvedResidentPort must return defaultResidentPort (4242) when
        // daemon.port does not exist — mirrors daemon_client::resolved_port fallback.
        let dataDir = URL(fileURLWithPath: "/tmp/mootx01-test-no-port-file-\(UUID().uuidString)", isDirectory: true)
        let port = MootPaths.resolvedResidentPort(dataDir: dataDir)
        #expect(port == MootPaths.defaultResidentPort) // 4242
    }

    @Test func resolvedResidentPortReadsPortFromFile() {
        // resolvedResidentPort must return the port written in daemon.port when
        // the file is present and valid — mirrors daemon_client::resolved_port
        // port-file-first resolution.
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mootx01-test-port-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let portFileURL = MootPaths.daemonPortFileURL(in: dataDir)
        try? "5050\n".write(to: portFileURL, atomically: true, encoding: .utf8)

        let port = MootPaths.resolvedResidentPort(dataDir: dataDir)
        #expect(port == 5050)
    }
}

/// The resident-estate predicate: the rule `mootx01 upgrade` uses to
/// decide whether a step may stop the resident daemon. Filesystem-touching
/// tests use their own uniquely-named temp directory.
@Suite("MootPaths resident estate")
struct ResidentEstateTests {

    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mootx01-resident-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func residentDataDirectoryIsTheDefaultWithNoOverride() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        #expect(
            MootPaths.residentDataDirectory(homeDirectory: home).path ==
            "/Users/test/Library/Application Support/com.mootx01.ce"
        )
    }

    @Test func residentDirectoryIsTheResidentEstate() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let resident = MootPaths.residentDataDirectory(homeDirectory: home)
        let resolved = MootPaths.resolveDataDirectory(environment: [:], homeDirectory: home)
        #expect(MootPaths.isResidentEstate(dataDirectory: resolved, residentDataDirectory: resident))
    }

    @Test func dotSegmentsAndTrailingSeparatorDoNotDefeatThePredicate() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let resident = MootPaths.residentDataDirectory(homeDirectory: home)
        let spelled = MootPaths.resolveDataDirectory(
            environment: ["MOOTX01_DATA_DIR": "/Users/test/Library/./Application Support/com.mootx01.ce/"],
            homeDirectory: home)
        #expect(MootPaths.isResidentEstate(dataDirectory: spelled, residentDataDirectory: resident))
    }

    @Test func symlinkToTheResidentDirectoryIsTheResidentEstate() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let resident = MootPaths.residentDataDirectory(homeDirectory: root)
        try FileManager.default.createDirectory(at: resident, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("estate-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: resident)
        let viaLink = MootPaths.resolveDataDirectory(
            environment: ["MOOTX01_DATA_DIR": link.path], homeDirectory: root)
        #expect(MootPaths.isResidentEstate(dataDirectory: viaLink, residentDataDirectory: resident))
    }

    @Test func siblingScratchDirectoryIsNotTheResidentEstate() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let resident = MootPaths.residentDataDirectory(homeDirectory: root)
        try FileManager.default.createDirectory(at: resident, withIntermediateDirectories: true)
        // A benchmark clone beside the resident directory: same parent,
        // same prefix, a different estate.
        let scratch = resident.deletingLastPathComponent()
            .appendingPathComponent("com.mootx01.ce-bench", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let resolved = MootPaths.resolveDataDirectory(
            environment: ["MOOTX01_DATA_DIR": scratch.path], homeDirectory: root)
        #expect(!MootPaths.isResidentEstate(dataDirectory: resolved, residentDataDirectory: resident))
    }

    @Test func nonExistentScratchDirectoryIsNotTheResidentEstate() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let resident = MootPaths.residentDataDirectory(homeDirectory: home)
        let resolved = MootPaths.resolveDataDirectory(
            environment: ["MOOTX01_DATA_DIR": "/Volumes/scratch/bench-clone"], homeDirectory: home)
        #expect(!MootPaths.isResidentEstate(dataDirectory: resolved, residentDataDirectory: resident))
    }
}
