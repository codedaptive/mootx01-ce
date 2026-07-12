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
