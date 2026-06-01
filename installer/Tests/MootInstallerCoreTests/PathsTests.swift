// PathsTests.swift
//
// Pure path-math tests for MootInstallerCore.MootPaths. No
// filesystem touching; the tests inject environment and home so
// they run identically under any user.

import Foundation
import Testing
@testable import MootInstallerCore

@Suite("MootPaths path math")
struct PathsTests {

    @Test("resolveDataDirectory defaults to Application Support")
    func resolveDataDirectoryDefaultsToApplicationSupport() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let resolved = MootPaths.resolveDataDirectory(
            environment: [:],
            homeDirectory: home
        )
        #expect(
            resolved.path == "/Users/test/Library/Application Support/MOOTx01"
        )
    }

    @Test("resolveDataDirectory honors the environment override")
    func resolveDataDirectoryHonorsEnvironmentOverride() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let resolved = MootPaths.resolveDataDirectory(
            environment: ["MOOTX01_DATA_DIR": "/tmp/sandbox-moot"],
            homeDirectory: home
        )
        #expect(resolved.path == "/tmp/sandbox-moot")
    }

    @Test("resolveDataDirectory ignores an empty override")
    func resolveDataDirectoryIgnoresEmptyOverride() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let resolved = MootPaths.resolveDataDirectory(
            environment: ["MOOTX01_DATA_DIR": ""],
            homeDirectory: home
        )
        #expect(
            resolved.path == "/Users/test/Library/Application Support/MOOTx01"
        )
    }

    @Test("estateURL appends the fixed filename")
    func estateURLAppendsFixedFilename() {
        let dir = URL(fileURLWithPath: "/Users/test/Library/Application Support/MOOTx01", isDirectory: true)
        let estate = MootPaths.estateURL(in: dir)
        #expect(
            estate.path == "/Users/test/Library/Application Support/MOOTx01/estate.sqlite"
        )
    }

    @Test("default owner identifier is non-empty")
    func defaultOwnerIdentifierIsNonEmpty() {
        // LocusKit.Estate.create rejects an empty owner identifier
        // up front; the default the installer stamps must satisfy
        // that precondition.
        #expect(!MootPaths.defaultOwnerIdentifier.isEmpty)
    }
}
