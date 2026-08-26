// LaunchAgentTests.swift
//
// Covers both the moot-mgr console LaunchAgent contract and the resident
// daemon plist/environment/path behavior: MootPaths helpers, the pure plist
// generator (LaunchAgent.makePlist + xmlEscape), daemon environment variables,
// daemon path resolution, and the filesystem behaviour of
// Installer.placeMgrBinary. The launchctl-invoking install/uninstall entry
// points are integration-verified manually (they mutate the user's launchd
// domain) and are not exercised here. Filesystem tests use a fresh
// UUID-named temp home per test, so the suite is safe under swift-testing's
// parallel execution.

import Foundation
import Testing
@testable import MootInstallerCore

@Suite("LaunchAgent & placeMgrBinary")
struct LaunchAgentTests {

    // MARK: - Paths

    @Test func mgrBinaryAndSymlinkPaths() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        #expect(
            MootPaths.installedMgrBinaryURL(homeDirectory: home).path ==
            "/Users/test/.mootx01/bin/moot-mgr"
        )
        #expect(
            MootPaths.mgrSymlinkURL(homeDirectory: home).path ==
            "/Users/test/.local/bin/moot-mgr"
        )
        #expect(
            MootPaths.logsDirURL(homeDirectory: home).path ==
            "/Users/test/.mootx01/logs"
        )
        #expect(
            MootPaths.launchAgentPlistURL(homeDirectory: home).path ==
            "/Users/test/Library/LaunchAgents/com.mootx01.mgr.plist"
        )
        #expect(MootPaths.launchAgentLabel == "com.mootx01.mgr")
    }

    // MARK: - Plist generation (pure)

    @Test func makePlistContainsBinaryServeAndKeepAlive() throws {
        let plist = LaunchAgent.makePlist(
            label: "com.mootx01.mgr",
            programArguments: ["/Users/test/.mootx01/bin/moot-mgr", "serve"],
            stdoutPath: "/Users/test/.mootx01/logs/moot-mgr.out.log",
            stderrPath: "/Users/test/.mootx01/logs/moot-mgr.err.log"
        )
        #expect(plist.contains("<string>com.mootx01.mgr</string>"))
        #expect(plist.contains("<string>/Users/test/.mootx01/bin/moot-mgr</string>"))
        #expect(plist.contains("<string>serve</string>"))
        #expect(plist.contains("<key>RunAtLoad</key>"))
        #expect(plist.contains("<key>KeepAlive</key>"))
        // Interactive, not Background: a Background ProcessType clamps the
        // whole daemon to efficiency cores (20x slower imports, starved tool
        // responses). See makePlist doc comment.
        #expect(plist.contains("<string>Interactive</string>"))
        #expect(plist.contains("moot-mgr.out.log"))
        #expect(plist.contains("moot-mgr.err.log"))
        // A plist with no env dict must NOT emit an EnvironmentVariables key.
        #expect(!plist.contains("<key>EnvironmentVariables</key>"))
        // Well-formed enough to parse as a property list.
        let data = Data(plist.utf8)
        _ = try PropertyListSerialization.propertyList(from: data, format: nil)
    }

    @Test func daemonPlistCarriesEnvironmentVariables() throws {
        let plist = LaunchAgent.makePlist(
            label: MootPaths.daemonLabel,
            programArguments: ["/Users/test/.mootx01/bin/mootx01", "serve"],
            stdoutPath: "/Users/test/.mootx01/logs/mootx01-daemon.out.log",
            stderrPath: "/Users/test/.mootx01/logs/mootx01-daemon.err.log",
            environmentVariables: [
                "MOOTX01_HTTP_PORT": "4242",
                "MOOTX01_DATA_DIR": "/Users/test/Library/Application Support/com.mootx01.ce",
                "ARIA_MCP_STATS_STORE": "/Users/test/Library/Application Support/com.mootx01.ce/moot-mgr/stats.sqlite",
            ]
        )
        #expect(plist.contains("<string>com.mootx01.daemon</string>"))
        #expect(plist.contains("<key>EnvironmentVariables</key>"))
        #expect(plist.contains("<key>MOOTX01_HTTP_PORT</key>"))
        #expect(plist.contains("<string>4242</string>"))
        #expect(plist.contains("<key>ARIA_MCP_STATS_STORE</key>"))
        // Parses as a real plist, and the env round-trips to the right values.
        let data = Data(plist.utf8)
        let obj = try PropertyListSerialization.propertyList(from: data, format: nil)
        let dict = try #require(obj as? [String: Any])
        let env = try #require(dict["EnvironmentVariables"] as? [String: String])
        #expect(env["MOOTX01_HTTP_PORT"] == "4242")
        #expect(env["ARIA_MCP_STATS_STORE"] == "/Users/test/Library/Application Support/com.mootx01.ce/moot-mgr/stats.sqlite")
    }

    @Test func daemonPaths() {
        let home = URL(fileURLWithPath: "/Users/test")
        #expect(MootPaths.daemonLabel == "com.mootx01.daemon")
        #expect(
            MootPaths.daemonPlistURL(homeDirectory: home).path ==
            "/Users/test/Library/LaunchAgents/com.mootx01.daemon.plist"
        )
        let dataDir = URL(fileURLWithPath: "/Users/test/Library/Application Support/com.mootx01.ce")
        #expect(
            MootPaths.daemonStatsStorePath(dataDir: dataDir) ==
            "/Users/test/Library/Application Support/com.mootx01.ce/moot-mgr/stats.sqlite"
        )
    }

    @Test func xmlEscapeHandlesSpecialCharacters() throws {
        #expect(
            LaunchAgent.xmlEscape("/Users/a&b/<c>/moot-mgr") ==
            "/Users/a&amp;b/&lt;c&gt;/moot-mgr"
        )
        // An ampersand in a path must not break plist parsing.
        let plist = LaunchAgent.makePlist(
            label: "com.mootx01.mgr",
            programArguments: ["/Users/a&b/moot-mgr", "serve"],
            stdoutPath: "/tmp/o.log",
            stderrPath: "/tmp/e.log"
        )
        _ = try PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil)
    }

    // MARK: - placeMgrBinary (filesystem)

    /// No source and nothing already placed → returns nil (caller skips agent).
    @Test func placeMgrBinaryReturnsNilWhenNothingAvailable() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let result = try Installer.placeMgrBinary(sourceMgrPath: nil, homeDirectory: home)
        #expect(result == nil)
    }

    /// A real source binary is copied into place and put onto PATH via the
    /// exec wrapper (a symlinked PATH entry breaks SPM resource-bundle
    /// lookup — see Installer.writePathWrapper).
    @Test func placeMgrBinaryPlacesAndWraps() throws {
        let fm = FileManager.default
        let home = try makeTempHome()
        defer { try? fm.removeItem(at: home) }

        // Fake "moot-mgr" source somewhere outside the install tree.
        let srcDir = home.appendingPathComponent("src", isDirectory: true)
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        let src = srcDir.appendingPathComponent("moot-mgr")
        try Data("#!/bin/sh\n".utf8).write(to: src)

        let placed = try Installer.placeMgrBinary(sourceMgrPath: src.path, homeDirectory: home)
        let dest = MootPaths.installedMgrBinaryURL(homeDirectory: home)
        let entry = MootPaths.mgrSymlinkURL(homeDirectory: home)

        #expect(placed == dest.path)
        #expect(fm.fileExists(atPath: dest.path))
        #expect(
            (try? fm.destinationOfSymbolicLink(atPath: entry.path)) == nil,
            "PATH entry must be a wrapper script, not a symlink"
        )
        let wrapper = try String(contentsOfFile: entry.path, encoding: .utf8)
        // The wrapper single-quotes the exec target (#15 shell-escape).
        #expect(
            wrapper.contains("exec '\(dest.path)' \"$@\""),
            "wrapper must exec the placed moot-mgr"
        )

        // Re-running is overwrite-safe (idempotent).
        _ = try Installer.placeMgrBinary(sourceMgrPath: src.path, homeDirectory: home)
    }

    // MARK: - Helpers

    private func makeTempHome() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mgr-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}

// MARK: - MACD-2c2 — daemon bundle installer parity (BRR §3.7-3.12)
//
// The signed app-like daemon bundle contract: one Swift constant surface
// (DaemonBundle) that the LaunchAgent plist, the pkg payload, the Makefile,
// build-pkg.sh, and release.yml all spell identically — verified here so
// generated and manual sources cannot diverge (KONG-4). Status honesty
// (P-c2-10): registration, PID, or an answering port is NEVER reported as a
// running/ready server.

@Suite("Daemon bundle constants and LaunchAgent contract (MACD-2c2)")
struct DaemonBundleContractTests {

    @Test("the constant surface spells the bundle artifact exactly once")
    func constantSurface() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        #expect(DaemonBundle.bundleName == "Mootx01DaemonProvider.app")
        #expect(DaemonBundle.executableName == "Mootx01DaemonProvider")
        #expect(DaemonBundle.launchAgentLabel == "com.codedaptive.mootx01.daemon")
        #expect(DaemonBundle.residentModeArgument == "resident")
        #expect(
            DaemonBundle.installedBundleURL(homeDirectory: home).path ==
            "/Users/test/.mootx01/bin/Mootx01DaemonProvider.app"
        )
        #expect(
            DaemonBundle.bundleExecutableURL(homeDirectory: home).path ==
            "/Users/test/.mootx01/bin/Mootx01DaemonProvider.app/Contents/MacOS/Mootx01DaemonProvider"
        )
        #expect(
            DaemonBundle.launchAgentPlistURL(homeDirectory: home).path ==
            "/Users/test/Library/LaunchAgents/com.codedaptive.mootx01.daemon.plist"
        )
        // The new label never collides with the legacy raw-serve label — the
        // legacy artifact is retained until authenticated readiness.
        #expect(DaemonBundle.launchAgentLabel != MootPaths.daemonLabel)
    }

    @Test("ProgramArguments point INSIDE the bundle Contents/MacOS, never at a raw binary")
    func programArgumentsInsideBundle() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let arguments = DaemonBundle.programArguments(homeDirectory: home)
        #expect(arguments == [
            "/Users/test/.mootx01/bin/Mootx01DaemonProvider.app/Contents/MacOS/Mootx01DaemonProvider",
            "resident",
        ])
        #expect(arguments[0].contains("/Contents/MacOS/"))
        // The forbidden raw form: a bare CLI binary with "serve".
        #expect(!arguments.contains("serve"))
    }

    @Test("the bundle plist is the DISABLED-install variant: no RunAtLoad, no KeepAlive")
    func disabledInstallVariant() throws {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let plist = LaunchAgent.makeDaemonBundlePlist(homeDirectory: home)
        let object = try PropertyListSerialization.propertyList(
            from: Data(plist.utf8), format: nil
        )
        let dict = try #require(object as? [String: Any])
        #expect(dict["Label"] as? String == DaemonBundle.launchAgentLabel)
        #expect(dict["RunAtLoad"] as? Bool == false)
        #expect(dict["KeepAlive"] as? Bool == false)
        let arguments = try #require(dict["ProgramArguments"] as? [String])
        #expect(arguments == DaemonBundle.programArguments(homeDirectory: home))
    }

    @Test("installDaemonBundleDisabled writes the plist, verifies it by readback, and never bootstraps")
    func disabledInstallWritesAndVerifies() throws {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bundle-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let status = LaunchAgent.installDaemonBundleDisabled(homeDirectory: home)
        guard case .installedDisabled(let plistPath) = status else {
            Issue.record("expected installedDisabled, got \(status)")
            return
        }
        #expect(plistPath == DaemonBundle.launchAgentPlistURL(homeDirectory: home).path)
        // Readback validation (P-c2-10): the on-disk bytes ARE the generator's.
        let onDisk = try String(contentsOfFile: plistPath, encoding: .utf8)
        #expect(onDisk == LaunchAgent.makeDaemonBundlePlist(homeDirectory: home))
    }

    @Test("a corrupted post-write readback is reported, not ignored")
    func readbackMismatchReported() throws {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bundle-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        // Pre-create the plist path as a DIRECTORY so the write fails.
        let plistURL = DaemonBundle.launchAgentPlistURL(homeDirectory: home)
        try fm.createDirectory(at: plistURL, withIntermediateDirectories: true)
        let status = LaunchAgent.installDaemonBundleDisabled(homeDirectory: home)
        guard case .launchctlFailed = status else {
            Issue.record("expected a reported failure, got \(status)")
            return
        }
    }
}

@Suite("Honest status vocabulary (MACD-2c2, P-c2-10)")
struct HonestStatusTests {

    @Test("an answering port alone is an unverified holder, never a running server")
    func portAloneNeverRunning() {
        let line = LaunchAgent.honestServerStatus(
            registration: .none, port: .answering, providerReportedState: nil
        )
        #expect(!line.lowercased().contains("running"))
        #expect(line.contains("unverified"))
    }

    @Test("registration alone is registered-not-started, never running")
    func registrationAloneNeverRunning() {
        let line = LaunchAgent.honestServerStatus(
            registration: .registered, port: .unbound, providerReportedState: nil
        )
        #expect(!line.lowercased().contains("running"))
        #expect(line.contains("registered"))
    }

    @Test("registration plus an answering port is still not readiness")
    func registrationPlusPortNeverRunning() {
        let line = LaunchAgent.honestServerStatus(
            registration: .registered, port: .answering, providerReportedState: nil
        )
        #expect(!line.lowercased().contains("running"))
    }

    @Test("only the provider's OWN authenticated report carries its state, verbatim")
    func providerReportVerbatim() {
        let line = LaunchAgent.honestServerStatus(
            registration: .registered, port: .answering, providerReportedState: "ready"
        )
        #expect(line.contains("ready"))
        // The provider's spelling is passed through, not re-derived — the
        // status surface owns no second copy of the arbiter vocabulary.
        let conflicted = LaunchAgent.honestServerStatus(
            registration: .none, port: .unbound, providerReportedState: "conflicted"
        )
        #expect(conflicted.contains("conflicted"))
    }

    @Test("nothing observed reports not installed")
    func nothingObserved() {
        let line = LaunchAgent.honestServerStatus(
            registration: .none, port: .unbound, providerReportedState: nil
        )
        #expect(line.contains("not installed"))
    }
}

@Suite("Uninstall preservation contract (MACD-2c2)")
struct UninstallPreservationTests {

    @Test("owned artifacts are only registrations and placed binaries — never estate, receipts, or backups")
    func ownedArtifactsNeverTouchEstate() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let owned = DaemonBundle.ownedArtifactPaths(homeDirectory: home)
        #expect(!owned.isEmpty)
        for path in owned {
            #expect(
                path.hasPrefix("/Users/test/Library/LaunchAgents/")
                    || path.hasPrefix("/Users/test/.mootx01/")
                    || path.hasPrefix("/Users/test/.local/bin/"),
                "owned artifact escapes the owned roots: \(path)"
            )
            #expect(!path.contains("Application Support"))
            #expect(!path.contains("estate.sqlite"))
            #expect(!path.contains("mootx01.sqlite"))
            #expect(!path.contains("receipt"))
            #expect(!path.contains("backup"))
        }
        // The bundle and both plists are owned.
        #expect(owned.contains(DaemonBundle.installedBundleURL(homeDirectory: home).path))
        #expect(owned.contains(DaemonBundle.launchAgentPlistURL(homeDirectory: home).path))
    }
}

@Suite("Distribution parity — one constant surface, three spellings (MACD-2c2)")
struct DistributionParityTests {

    /// Repo root, located from this file's path:
    /// apps/mootx01/Tests/MootInstallerCoreTests/LaunchAgentTests.swift.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MootInstallerCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // mootx01
            .deletingLastPathComponent()  // apps
            .deletingLastPathComponent()  // repo root
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8
        )
    }

    @Test("build-pkg.sh stages the daemon bundle under the constant's name")
    func buildPkgParity() throws {
        let script = try contents("distribution/macos/build-pkg.sh")
        #expect(script.contains(DaemonBundle.bundleName))
        #expect(script.contains(DaemonBundle.executableName))
    }

    @Test("pkg upgrade restarts both Community provider and legacy resident services")
    func postinstallRestartParity() throws {
        let script = try contents("distribution/macos/scripts/postinstall")
        #expect(script.contains("gui/$REAL_UID/\(DaemonBundle.launchAgentLabel)"))
        #expect(script.contains("gui/$REAL_UID/\(MootPaths.daemonLabel)"))
        #expect(script.contains("gui/$REAL_UID/\(MootPaths.launchAgentLabel)"))
    }

    @Test("the Makefile pkg recipe builds and passes the daemon shell artifact")
    func makefileParity() throws {
        let makefile = try contents("Makefile")
        #expect(makefile.contains("mootx01-daemon"))
        #expect(makefile.contains(DaemonBundle.bundleName))
    }

    @Test("release.yml builds and stages the same artifact spellings")
    func releaseParity() throws {
        let workflow = try contents(".github/workflows/release.yml")
        #expect(workflow.contains("mootx01-daemon"))
        #expect(workflow.contains(DaemonBundle.bundleName))
    }
}
