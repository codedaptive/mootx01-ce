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

    /// The platform-default directory under `home`, as the daemon serves it
    /// when its registration carries no override.
    private func platformDefault(_ home: URL) -> URL {
        MootPaths.resolveDataDirectory(environment: [:], homeDirectory: home)
    }

    @Test func residentDataDirectoryIsTheDefaultWithNoRegistration() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        #expect(
            MootPaths.registeredResidentDataDirectory(homeDirectory: home, daemonPlist: nil) ==
            .directory(URL(fileURLWithPath: "/Users/test/Library/Application Support/com.mootx01.ce", isDirectory: true))
        )
    }

    @Test func residentDirectoryIsTheResidentEstate() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let resident = MootPaths.registeredResidentDataDirectory(homeDirectory: home, daemonPlist: nil)
        let resolved = MootPaths.resolveDataDirectory(environment: [:], homeDirectory: home)
        #expect(MootPaths.isResidentEstate(dataDirectory: resolved, residentDataDirectory: resident))
    }

    @Test func dotSegmentsAndTrailingSeparatorDoNotDefeatThePredicate() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let resident = MootPaths.ResidentDataDirectory.directory(platformDefault(home))
        let spelled = MootPaths.resolveDataDirectory(
            environment: ["MOOTX01_DATA_DIR": "/Users/test/Library/./Application Support/com.mootx01.ce/"],
            homeDirectory: home)
        #expect(MootPaths.isResidentEstate(dataDirectory: spelled, residentDataDirectory: resident))
    }

    @Test func symlinkToTheResidentDirectoryIsTheResidentEstate() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let resident = platformDefault(root)
        try FileManager.default.createDirectory(at: resident, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("estate-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: resident)
        let viaLink = MootPaths.resolveDataDirectory(
            environment: ["MOOTX01_DATA_DIR": link.path], homeDirectory: root)
        #expect(MootPaths.isResidentEstate(
            dataDirectory: viaLink, residentDataDirectory: .directory(resident)))
    }

    @Test func siblingScratchDirectoryIsNotTheResidentEstate() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let resident = platformDefault(root)
        try FileManager.default.createDirectory(at: resident, withIntermediateDirectories: true)
        // A benchmark clone beside the resident directory: same parent,
        // same prefix, a different estate.
        let scratch = resident.deletingLastPathComponent()
            .appendingPathComponent("com.mootx01.ce-bench", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let resolved = MootPaths.resolveDataDirectory(
            environment: ["MOOTX01_DATA_DIR": scratch.path], homeDirectory: root)
        #expect(!MootPaths.isResidentEstate(
            dataDirectory: resolved, residentDataDirectory: .directory(resident)))
    }

    @Test func nonExistentScratchDirectoryIsNotTheResidentEstate() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let resident = MootPaths.ResidentDataDirectory.directory(platformDefault(home))
        let resolved = MootPaths.resolveDataDirectory(
            environment: ["MOOTX01_DATA_DIR": "/Volumes/scratch/bench-clone"], homeDirectory: home)
        #expect(!MootPaths.isResidentEstate(dataDirectory: resolved, residentDataDirectory: resident))
    }

    // MARK: - The resident directory comes from the daemon registration

    /// The exact plist `mootx01 install` writes (`LaunchAgent.installDaemon`
    /// → `makePlist`), with the environment it bakes in. What install
    /// writes is what upgrade must read back.
    private func installedDaemonPlist(environment: [String: String]) -> Data {
        Data(LaunchAgent.makePlist(
            label: MootPaths.daemonLabel,
            programArguments: ["/Users/test/.mootx01/bin/mootx01", "serve"],
            stdoutPath: "/Users/test/.mootx01/logs/out.log",
            stderrPath: "/Users/test/.mootx01/logs/err.log",
            environmentVariables: environment
        ).utf8)
    }

    @Test("a registration that bakes MOOTX01_DATA_DIR=/x names /x as the resident directory")
    func registrationWithOverrideNamesThatDirectory() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let plist = installedDaemonPlist(environment: [
            "MOOTX01_HTTP_PORT": "4242",
            "MOOTX01_DATA_DIR": "/x",
        ])
        let resident = MootPaths.registeredResidentDataDirectory(homeDirectory: home, daemonPlist: plist)
        #expect(resident == .directory(URL(fileURLWithPath: "/x", isDirectory: true)))
        // The daemon's estate is /x: a step on /x quiesces, a step on the
        // platform default (an estate the daemon never opened) does not.
        #expect(MootPaths.isResidentEstate(
            dataDirectory: URL(fileURLWithPath: "/x", isDirectory: true), residentDataDirectory: resident))
        #expect(!MootPaths.isResidentEstate(
            dataDirectory: platformDefault(home), residentDataDirectory: resident))
    }

    @Test("a registration without MOOTX01_DATA_DIR means the platform default")
    func registrationWithoutOverrideIsThePlatformDefault() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let noVariable = installedDaemonPlist(environment: ["MOOTX01_HTTP_PORT": "4242"])
        #expect(MootPaths.registeredResidentDataDirectory(homeDirectory: home, daemonPlist: noVariable)
                == .directory(platformDefault(home)))
        let emptyVariable = installedDaemonPlist(environment: ["MOOTX01_DATA_DIR": ""])
        #expect(MootPaths.registeredResidentDataDirectory(homeDirectory: home, daemonPlist: emptyVariable)
                == .directory(platformDefault(home)))
        let noEnvironmentBlock = installedDaemonPlist(environment: [:])
        #expect(MootPaths.registeredResidentDataDirectory(homeDirectory: home, daemonPlist: noEnvironmentBlock)
                == .directory(platformDefault(home)))
    }

    @Test("a registration that cannot be parsed makes every estate resident")
    func unparsableRegistrationMakesEveryEstateResident() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let plistURL = MootPaths.daemonPlistURL(homeDirectory: home)
        let garbage = Data("this is not a plist".utf8)
        let resident = MootPaths.registeredResidentDataDirectory(homeDirectory: home, daemonPlist: garbage)
        #expect(resident == .unreadableRegistration(plistURL))
        #expect(MootPaths.isResidentEstate(
            dataDirectory: URL(fileURLWithPath: "/Volumes/scratch/bench-clone", isDirectory: true),
            residentDataDirectory: resident))
        #expect(MootPaths.isResidentEstate(
            dataDirectory: platformDefault(home), residentDataDirectory: resident))
        #expect(resident.registrationWarning(for: platformDefault(home))?.contains(plistURL.path) == true)
        // A file that exists but is empty is a registration we cannot read.
        #expect(MootPaths.registeredResidentDataDirectory(homeDirectory: home, daemonPlist: Data())
                == .unreadableRegistration(plistURL))
        // A well-formed plist whose EnvironmentVariables is not a string
        // dictionary is a registration we cannot read either.
        let wrongShape = try? PropertyListSerialization.data(
            fromPropertyList: ["Label": "x", "EnvironmentVariables": ["MOOTX01_DATA_DIR"]],
            format: .xml, options: 0)
        #expect(MootPaths.registeredResidentDataDirectory(homeDirectory: home, daemonPlist: wrongShape)
                == .unreadableRegistration(plistURL))
    }

    @Test("residentDataDirectory reads the daemon plist under the home directory")
    func residentDataDirectoryReadsThePlistOnDisk() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plistURL = MootPaths.daemonPlistURL(homeDirectory: root)

        // Absent: the platform default under this home.
        #expect(MootPaths.residentDataDirectory(homeDirectory: root) == .directory(platformDefault(root)))

        // Present with an override: the override, not the default. This is
        // the install-with-MOOTX01_DATA_DIR then upgrade-with-the-same-override
        // case: the step on the override directory must quiesce.
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let custom = root.appendingPathComponent("custom-estate", isDirectory: true)
        try installedDaemonPlist(environment: ["MOOTX01_DATA_DIR": custom.path]).write(to: plistURL)
        let registered = MootPaths.residentDataDirectory(homeDirectory: root)
        #expect(registered == .directory(URL(fileURLWithPath: custom.path, isDirectory: true)))
        #expect(MootPaths.isResidentEstate(dataDirectory: custom, residentDataDirectory: registered))
        #expect(!MootPaths.isResidentEstate(dataDirectory: platformDefault(root), residentDataDirectory: registered))

        // Present but unparsable: unreadable, and every estate is resident.
        try Data("<plist".utf8).write(to: plistURL)
        let unreadable = MootPaths.residentDataDirectory(homeDirectory: root)
        #expect(unreadable == .unreadableRegistration(plistURL))
        #expect(MootPaths.isResidentEstate(dataDirectory: platformDefault(root), residentDataDirectory: unreadable))
    }
}
