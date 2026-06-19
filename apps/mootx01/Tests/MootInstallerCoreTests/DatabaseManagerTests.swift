// DatabaseManagerTests.swift
//
// Unit tests for DatabaseManager: estate URL resolution, config
// round-trips, CRUD operations, and error cases. All I/O goes to
// a temporary directory so no real user data is touched.

import Testing
import Foundation
@testable import MootInstallerCore

@Suite("DatabaseManager")
struct DatabaseManagerTests {

    // MARK: - estateURL resolution

    @Test("default estate uses legacy flat path under dataDirectory")
    func defaultEstateURL() {
        let dataDir = URL(fileURLWithPath: "/tmp/test-data")
        let url = DatabaseManager.estateURL(for: "default", in: dataDir)
        #expect(url.lastPathComponent == "estate.sqlite")
        #expect(url.deletingLastPathComponent().path == "/tmp/test-data")
    }

    @Test("named estate uses databases/<name>/estate.sqlite path")
    func namedEstateURL() {
        let dataDir = URL(fileURLWithPath: "/tmp/test-data")
        let url = DatabaseManager.estateURL(for: "work", in: dataDir)
        #expect(url.lastPathComponent == "estate.sqlite")
        #expect(url.path.contains("/databases/work/"))
    }

    // MARK: - Config (active estate pointer)

    @Test("activeEstateName returns 'default' when config absent")
    func activeEstateNameDefaultWhenAbsent() throws {
        let dataDir = try makeTempDir()
        defer { cleanupTempDir(dataDir) }

        let name = try DatabaseManager.activeEstateName(in: dataDir)
        #expect(name == "default")
    }

    @Test("setActiveEstate and activeEstateName round-trip")
    func activeEstateRoundTrip() throws {
        let dataDir = try makeTempDir()
        defer { cleanupTempDir(dataDir) }

        try DatabaseManager.setActiveEstate("work", in: dataDir)
        let name = try DatabaseManager.activeEstateName(in: dataDir)
        #expect(name == "work")
    }

    @Test("setActiveEstate creates data directory if absent")
    func setActiveEstateCreatesDir() throws {
        let base = try makeTempDir()
        defer { cleanupTempDir(base) }
        // Nest one level deeper so the directory doesn't exist yet.
        let dataDir = base.appendingPathComponent("nested/data")
        try DatabaseManager.setActiveEstate("test", in: dataDir)
        #expect(FileManager.default.fileExists(atPath: dataDir.path))
    }

    // MARK: - createEstate

    @Test("createEstate creates the estate directory")
    func createEstateCreatesDirectory() throws {
        let dataDir = try makeTempDir()
        defer { cleanupTempDir(dataDir) }

        try DatabaseManager.createEstate(name: "myestate", in: dataDir)
        let dir = DatabaseManager.estateURL(for: "myestate", in: dataDir)
            .deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }

    @Test("createEstate throws alreadyExists on second call with same name")
    func createEstateThrowsOnDuplicate() throws {
        let dataDir = try makeTempDir()
        defer { cleanupTempDir(dataDir) }

        try DatabaseManager.createEstate(name: "dup", in: dataDir)
        #expect(throws: MOOTx01DatabaseError.self) {
            try DatabaseManager.createEstate(name: "dup", in: dataDir)
        }
    }

    @Test("createEstate throws invalidName for empty name")
    func createEstateThrowsOnEmptyName() {
        let dataDir = URL(fileURLWithPath: "/tmp/irrelevant")
        #expect(throws: MOOTx01DatabaseError.self) {
            try DatabaseManager.createEstate(name: "", in: dataDir)
        }
    }

    // MARK: - listEstates

    @Test("listEstates returns empty array when data directory is empty")
    func listEstatesEmptyDir() throws {
        let dataDir = try makeTempDir()
        defer { cleanupTempDir(dataDir) }
        let names = DatabaseManager.listEstates(in: dataDir)
        #expect(names.isEmpty)
    }

    @Test("listEstates includes named estates immediately after createEstate")
    func listEstatesIncludesCreated() throws {
        let dataDir = try makeTempDir()
        defer { cleanupTempDir(dataDir) }

        try DatabaseManager.createEstate(name: "alpha", in: dataDir)
        try DatabaseManager.createEstate(name: "beta", in: dataDir)
        let names = DatabaseManager.listEstates(in: dataDir)
        // listEstates detects estates by directory presence — the SQLite file is
        // written lazily by the substrate on first serve, so it may not exist yet.
        // db create creates the directory; that is sufficient to make the estate
        // discoverable by db list and db open.
        #expect(names == ["alpha", "beta"])
    }

    @Test("create → list → open round-trip: estate is discoverable before first serve")
    func createListOpenRoundTrip() throws {
        let dataDir = try makeTempDir()
        defer { cleanupTempDir(dataDir) }

        // Create an estate — no sqlite file yet (substrate writes it on first serve).
        try DatabaseManager.createEstate(name: "driver", in: dataDir)

        // list must find it even though estate.sqlite does not exist.
        let listed = DatabaseManager.listEstates(in: dataDir)
        #expect(listed.contains("driver"), "db list must show estate after db create")

        // The estate directory must exist.
        let estateDir = DatabaseManager.estateURL(for: "driver", in: dataDir)
            .deletingLastPathComponent()
        var isDir: ObjCBool = false
        #expect(
            FileManager.default.fileExists(atPath: estateDir.path, isDirectory: &isDir)
                && isDir.boolValue,
            "estate directory must exist at databases/driver/"
        )

        // db open: set active estate must succeed — directory exists, file need not.
        try DatabaseManager.setActiveEstate("driver", in: dataDir)
        let active = try DatabaseManager.activeEstateName(in: dataDir)
        #expect(active == "driver", "active estate must be 'driver' after db open")
    }

    @Test("listEstates includes default when estate.sqlite exists")
    func listEstatesIncludesDefault() throws {
        let dataDir = try makeTempDir()
        defer { cleanupTempDir(dataDir) }

        // Create a placeholder estate.sqlite to simulate an initialised estate.
        let estateURL = MootPaths.estateURL(in: dataDir)
        try Data().write(to: estateURL)

        let names = DatabaseManager.listEstates(in: dataDir)
        #expect(names.contains("default"))
    }

    // MARK: - deleteEstate

    @Test("deleteEstate removes the estate directory")
    func deleteEstateRemovesDir() throws {
        let dataDir = try makeTempDir()
        defer { cleanupTempDir(dataDir) }

        try DatabaseManager.createEstate(name: "toDelete", in: dataDir)
        let dir = DatabaseManager.estateURL(for: "toDelete", in: dataDir)
            .deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: dir.path))

        try DatabaseManager.deleteEstate(name: "toDelete", in: dataDir)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test("deleteEstate throws deleteDefault for 'default'")
    func deleteEstateThrowsForDefault() {
        let dataDir = URL(fileURLWithPath: "/tmp/irrelevant")
        #expect(throws: MOOTx01DatabaseError.self) {
            try DatabaseManager.deleteEstate(name: "default", in: dataDir)
        }
    }

    @Test("deleteEstate throws notFound when estate does not exist")
    func deleteEstateThrowsNotFound() throws {
        let dataDir = try makeTempDir()
        defer { cleanupTempDir(dataDir) }
        #expect(throws: MOOTx01DatabaseError.self) {
            try DatabaseManager.deleteEstate(name: "ghost", in: dataDir)
        }
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dbmgr-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func cleanupTempDir(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
