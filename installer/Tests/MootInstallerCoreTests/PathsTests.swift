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
}
