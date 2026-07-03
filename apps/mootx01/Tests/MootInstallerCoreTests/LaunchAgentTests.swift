// LaunchAgentTests.swift
//
// Covers both the moot-mgr console LaunchAgent contract and the resident
// daemon plist/environment/path behavior: MootPaths helpers, the pure plist
// generator (LaunchAgent.makePlist + xmlEscape), daemon environment variables,
// daemon path resolution, and the filesystem behaviour of
// Installer.placeMgrBinary. The launchctl-invoking install/uninstall entry
// points are integration-verified manually (they mutate the user's launchd
// domain) and are not exercised here.

import XCTest
@testable import MootInstallerCore

final class LaunchAgentTests: XCTestCase {

    // MARK: - Paths

    func testMgrBinaryAndSymlinkPaths() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        XCTAssertEqual(
            MootPaths.installedMgrBinaryURL(homeDirectory: home).path,
            "/Users/test/.mootx01/bin/moot-mgr"
        )
        XCTAssertEqual(
            MootPaths.mgrSymlinkURL(homeDirectory: home).path,
            "/Users/test/.local/bin/moot-mgr"
        )
        XCTAssertEqual(
            MootPaths.logsDirURL(homeDirectory: home).path,
            "/Users/test/.mootx01/logs"
        )
        XCTAssertEqual(
            MootPaths.launchAgentPlistURL(homeDirectory: home).path,
            "/Users/test/Library/LaunchAgents/com.mootx01.mgr.plist"
        )
        XCTAssertEqual(MootPaths.launchAgentLabel, "com.mootx01.mgr")
    }

    // MARK: - Plist generation (pure)

    func testMakePlistContainsBinaryServeAndKeepAlive() {
        let plist = LaunchAgent.makePlist(
            label: "com.mootx01.mgr",
            programArguments: ["/Users/test/.mootx01/bin/moot-mgr", "serve"],
            stdoutPath: "/Users/test/.mootx01/logs/moot-mgr.out.log",
            stderrPath: "/Users/test/.mootx01/logs/moot-mgr.err.log"
        )
        XCTAssertTrue(plist.contains("<string>com.mootx01.mgr</string>"))
        XCTAssertTrue(plist.contains("<string>/Users/test/.mootx01/bin/moot-mgr</string>"))
        XCTAssertTrue(plist.contains("<string>serve</string>"))
        XCTAssertTrue(plist.contains("<key>RunAtLoad</key>"))
        XCTAssertTrue(plist.contains("<key>KeepAlive</key>"))
        XCTAssertTrue(plist.contains("<string>Background</string>"))
        XCTAssertTrue(plist.contains("moot-mgr.out.log"))
        XCTAssertTrue(plist.contains("moot-mgr.err.log"))
        // A plist with no env dict must NOT emit an EnvironmentVariables key.
        XCTAssertFalse(plist.contains("<key>EnvironmentVariables</key>"))
        // Well-formed enough to parse as a property list.
        let data = Data(plist.utf8)
        XCTAssertNoThrow(try PropertyListSerialization.propertyList(from: data, format: nil))
    }

    func testDaemonPlistCarriesEnvironmentVariables() throws {
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
        XCTAssertTrue(plist.contains("<string>com.mootx01.daemon</string>"))
        XCTAssertTrue(plist.contains("<key>EnvironmentVariables</key>"))
        XCTAssertTrue(plist.contains("<key>MOOTX01_HTTP_PORT</key>"))
        XCTAssertTrue(plist.contains("<string>4242</string>"))
        XCTAssertTrue(plist.contains("<key>ARIA_MCP_STATS_STORE</key>"))
        // Parses as a real plist, and the env round-trips to the right values.
        let data = Data(plist.utf8)
        let obj = try PropertyListSerialization.propertyList(from: data, format: nil)
        let dict = try XCTUnwrap(obj as? [String: Any])
        let env = try XCTUnwrap(dict["EnvironmentVariables"] as? [String: String])
        XCTAssertEqual(env["MOOTX01_HTTP_PORT"], "4242")
        XCTAssertEqual(env["ARIA_MCP_STATS_STORE"], "/Users/test/Library/Application Support/com.mootx01.ce/moot-mgr/stats.sqlite")
    }

    func testDaemonPaths() {
        let home = URL(fileURLWithPath: "/Users/test")
        XCTAssertEqual(MootPaths.daemonLabel, "com.mootx01.daemon")
        XCTAssertEqual(
            MootPaths.daemonPlistURL(homeDirectory: home).path,
            "/Users/test/Library/LaunchAgents/com.mootx01.daemon.plist"
        )
        let dataDir = URL(fileURLWithPath: "/Users/test/Library/Application Support/com.mootx01.ce")
        XCTAssertEqual(
            MootPaths.daemonStatsStorePath(dataDir: dataDir),
            "/Users/test/Library/Application Support/com.mootx01.ce/moot-mgr/stats.sqlite"
        )
    }

    func testXmlEscapeHandlesSpecialCharacters() {
        XCTAssertEqual(
            LaunchAgent.xmlEscape("/Users/a&b/<c>/moot-mgr"),
            "/Users/a&amp;b/&lt;c&gt;/moot-mgr"
        )
        // An ampersand in a path must not break plist parsing.
        let plist = LaunchAgent.makePlist(
            label: "com.mootx01.mgr",
            programArguments: ["/Users/a&b/moot-mgr", "serve"],
            stdoutPath: "/tmp/o.log",
            stderrPath: "/tmp/e.log"
        )
        XCTAssertNoThrow(
            try PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil)
        )
    }

    // MARK: - placeMgrBinary (filesystem)

    /// No source and nothing already placed → returns nil (caller skips agent).
    func testPlaceMgrBinaryReturnsNilWhenNothingAvailable() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let result = try Installer.placeMgrBinary(sourceMgrPath: nil, homeDirectory: home)
        XCTAssertNil(result)
    }

    /// A real source binary is copied into place and put onto PATH via the
    /// exec wrapper (a symlinked PATH entry breaks SPM resource-bundle
    /// lookup — see Installer.writePathWrapper).
    func testPlaceMgrBinaryPlacesAndWraps() throws {
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

        XCTAssertEqual(placed, dest.path)
        XCTAssertTrue(fm.fileExists(atPath: dest.path))
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: entry.path),
                     "PATH entry must be a wrapper script, not a symlink")
        let wrapper = try String(contentsOfFile: entry.path, encoding: .utf8)
        XCTAssertTrue(wrapper.contains("exec \"\(dest.path)\" \"$@\""),
                      "wrapper must exec the placed moot-mgr")

        // Re-running is overwrite-safe (idempotent).
        XCTAssertNoThrow(try Installer.placeMgrBinary(sourceMgrPath: src.path, homeDirectory: home))
    }

    // MARK: - Helpers

    private func makeTempHome() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mgr-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}
