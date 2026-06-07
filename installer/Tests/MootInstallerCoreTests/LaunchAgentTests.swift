// LaunchAgentTests.swift
//
// Covers the moot-mgr LaunchAgent contract: the new MootPaths helpers, the
// pure plist generator (LaunchAgent.makePlist + xmlEscape), and the
// filesystem behaviour of Installer.placeMgrBinary. The launchctl-invoking
// install/uninstall entry points are integration-verified manually (they
// mutate the user's launchd domain) and are not exercised here.

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
            mgrBinaryPath: "/Users/test/.mootx01/bin/moot-mgr",
            label: "com.mootx01.mgr",
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
        // Well-formed enough to parse as a property list.
        let data = Data(plist.utf8)
        XCTAssertNoThrow(try PropertyListSerialization.propertyList(from: data, format: nil))
    }

    func testXmlEscapeHandlesSpecialCharacters() {
        XCTAssertEqual(
            LaunchAgent.xmlEscape("/Users/a&b/<c>/moot-mgr"),
            "/Users/a&amp;b/&lt;c&gt;/moot-mgr"
        )
        // An ampersand in a path must not break plist parsing.
        let plist = LaunchAgent.makePlist(
            mgrBinaryPath: "/Users/a&b/moot-mgr",
            label: "com.mootx01.mgr",
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

    /// A real source binary is copied into place and symlinked onto PATH.
    func testPlaceMgrBinaryPlacesAndSymlinks() throws {
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
        let link = MootPaths.mgrSymlinkURL(homeDirectory: home)

        XCTAssertEqual(placed, dest.path)
        XCTAssertTrue(fm.fileExists(atPath: dest.path))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), dest.path)

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
