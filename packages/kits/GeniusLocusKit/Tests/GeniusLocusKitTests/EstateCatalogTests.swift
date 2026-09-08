// EstateCatalogTests.swift
//
// The catalog manages estatecatalog.json: create, read, update, delete of the
// registry records. It never touches an estate's files.
//
// Coverage:
//   1. createWritesTheDefaultRecordAndIsIdempotent
//   2. openCreatesWhenAbsentAndLoadsWhenPresent (and platformDirectoryIs...)
//   3. loadReadsRelativeAndAbsolutePaths
//   4. loadRefusesMissingUnreadableAndEmpty
//   5. registerAppendsAndSaves; duplicates and bad names refused
//   6. relocateRenameActivateRemoveEachSave; unknown names refused
//   7. removeRefusesTheActiveRecord
//   8. recordSpellsEveryOwnedFile
//   9. theCatalogNeverTouchesEstateFiles
//  10. selectorSplitsValueIntoPathAndName
//  11. dbValueSelectsRegisteredOrAttachesTransient; transient never saved
//  12. registerFromValueLandsWhereDbWouldLook
//  13. moveDefaultRefusesInThisVersion
//  14. estateManifestRoundTripsInsideTheEstateDirectory
//  15. estateManifestRefusesMissingForeignAndRenamed
//  16. transientAttachRefusesARogueManifest — foreign name, unknown key, symlinked file
//  17. backendRoundTripsAndDefaultsToSQLite — PostgreSQL entry carries its connection string
//  18. loadRefusesAMalformedBackendEntry

import Foundation
import MootProductIdentity
import Testing
@testable import GeniusLocusKit

@Suite("EstateCatalog", .serialized)   // the tests share the platform-directory override
struct EstateCatalogTests {

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("estate-catalog-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Point the catalog's platform directory at a scratch directory for one test.
    private func configuration() throws -> URL {
        let data = try scratch()
        EstateCatalog.configurationDirectoryOverride = data
        return data
    }

    private func file(_ data: URL) throws -> EstateCatalog.CatalogFile {
        try JSONDecoder().decode(EstateCatalog.CatalogFile.self,
                                 from: Data(contentsOf: EstateCatalog.catalogURL))
    }
    private func fileEntries(_ data: URL) throws -> [EstateCatalog.CatalogFile.Entry] { try file(data).estates }

    @Test func createWritesTheDefaultRecordAndIsIdempotent() throws {
        let data = try configuration()
        defer { try? FileManager.default.removeItem(at: data); EstateCatalog.configurationDirectoryOverride = nil }
        let catalog = try EstateCatalog.create()
        #expect(catalog.records.count == 1)
        #expect(catalog.active.name == "default")
        #expect(catalog.defaultLocation == data.appendingPathComponent("databases", isDirectory: true).standardizedFileURL)
        #expect(catalog.active.directory == catalog.directory(forBareName: "default"))
        #expect(try file(data).defaultLocation == data.standardizedFileURL.path + "/databases")
        #expect(try fileEntries(data) == [.init(name: "default", path: data.standardizedFileURL.path + "/databases/default")])
        var again = try EstateCatalog.create()
        #expect(again == catalog)
        try again.register(name: "extra", directory: data.appendingPathComponent("databases/extra"))
        #expect(try EstateCatalog.create().records.count == 2)   // did not overwrite
    }

    @Test func platformDirectoryIsApplicationSupportPlusProductIdentifier() {
        EstateCatalog.configurationDirectoryOverride = nil
        // The test process is unsandboxed, so the family home is the user's home.
        let expected = MootProductIdentity.Storage.processHome()
            .appendingPathComponent("Library/Application Support/\(EstateCatalog.productIdentifier)", isDirectory: true)
            .standardizedFileURL
        #expect(expected == URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/\(EstateCatalog.productIdentifier)", isDirectory: true)
            .standardizedFileURL)
        #expect(EstateCatalog.configurationDirectory == expected)
        #expect(EstateCatalog.catalogURL.lastPathComponent == "estatecatalog.json")
        #expect(EstateCatalog.initialDefaultLocation == expected.appendingPathComponent("databases", isDirectory: true).standardizedFileURL)
        #expect(EstateCatalog.productIdentifier == MootProductIdentity.Storage.applicationSupportFolder)
    }

    @Test func openCreatesWhenAbsentAndLoadsWhenPresent() throws {
        let data = try configuration()
        defer { try? FileManager.default.removeItem(at: data); EstateCatalog.configurationDirectoryOverride = nil }
        #expect(EstateCatalog.configurationDirectory == data)
        #expect(EstateCatalog.catalogURL == data.appendingPathComponent("estatecatalog.json"))
        #expect(!FileManager.default.fileExists(atPath: EstateCatalog.catalogURL.path))
        let first = try EstateCatalog.open()
        #expect(first.active.name == "default")
        #expect(try EstateCatalog.open() == first)
    }

    @Test func loadReadsTheDefaultLocationAndAbsolutePaths() throws {
        let data = try configuration()
        defer { try? FileManager.default.removeItem(at: data); EstateCatalog.configurationDirectoryOverride = nil }
        let external = try scratch()
        defer { try? FileManager.default.removeItem(at: external) }
        let json = """
        {"version": 1, "defaultLocation": "/Volumes/moot/databases", "estates": [
          {"name": "research", "path": "\(external.path)"},
          {"name": "default", "path": "/Volumes/moot/databases/default"}
        ]}
        """
        try json.write(to: EstateCatalog.catalogURL, atomically: true, encoding: .utf8)
        let catalog = try EstateCatalog.load()
        #expect(catalog.records.map(\.name) == ["research", "default"])
        #expect(catalog.active.name == "research")                       // index zero is active, whatever its name
        #expect(catalog.active.directory == external.standardizedFileURL)
        #expect(catalog.defaultLocation == URL(fileURLWithPath: "/Volumes/moot/databases", isDirectory: true))
        #expect(catalog.record(named: "default")?.directory == URL(fileURLWithPath: "/Volumes/moot/databases/default", isDirectory: true))
        #expect(catalog.directory(forBareName: "x") == URL(fileURLWithPath: "/Volumes/moot/databases/x", isDirectory: true))
        #expect(catalog.record(named: "nope") == nil)
    }

    @Test func loadRefusesMissingUnreadableAndEmpty() throws {
        let data = try configuration()
        defer { try? FileManager.default.removeItem(at: data); EstateCatalog.configurationDirectoryOverride = nil }
        let url = EstateCatalog.catalogURL
        var thrown: EstateCatalogError?
        do { _ = try EstateCatalog.load() } catch let e as EstateCatalogError { thrown = e }
        guard case .unreadableCatalog? = thrown else { Issue.record("missing file: \(String(describing: thrown))"); return }
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        thrown = nil
        do { _ = try EstateCatalog.load() } catch let e as EstateCatalogError { thrown = e }
        guard case .unreadableCatalog? = thrown else { Issue.record("bad json: \(String(describing: thrown))"); return }
        try #"{"version": 1, "defaultLocation": "/d", "estates": []}"#.write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: EstateCatalogError.emptyCatalog(url: url)) { try EstateCatalog.load() }
        try #"{"version": 1, "defaultLocation": "relative/x", "estates": [{"name": "default", "path": "/x"}]}"#.write(to: url, atomically: true, encoding: .utf8)
        thrown = nil
        do { _ = try EstateCatalog.load() } catch let e as EstateCatalogError { thrown = e }
        guard case .unreadableCatalog? = thrown else { Issue.record("relative default: \(String(describing: thrown))"); return }
        try #"{"version": 99, "defaultLocation": "/d", "estates": [{"name": "default", "path": "/x"}]}"#.write(to: url, atomically: true, encoding: .utf8)
        thrown = nil
        do { _ = try EstateCatalog.load() } catch let e as EstateCatalogError { thrown = e }
        guard case .unreadableCatalog? = thrown else { Issue.record("version: \(String(describing: thrown))"); return }
    }

    @Test func registerAppendsAndSaves() throws {
        let data = try configuration()
        defer { try? FileManager.default.removeItem(at: data); EstateCatalog.configurationDirectoryOverride = nil }
        var catalog = try EstateCatalog.create()
        let external = URL(fileURLWithPath: "/Volumes/work/moot/research", isDirectory: true)
        try catalog.register(name: "research", directory: external)
        #expect(catalog.records.map(\.name) == ["default", "research"])
        #expect(catalog.active.name == "default")
        #expect(try fileEntries(data) == [.init(name: "default", path: catalog.directory(forBareName: "default").path),
                                          .init(name: "research", path: "/Volumes/work/moot/research")])
        #expect(try EstateCatalog.load() == catalog)
        #expect(throws: EstateCatalogError.duplicateName("research")) {
            try catalog.register(name: "research", directory: external)
        }
        for bad in ["", ".", "..", "a/b", "a\\b"] {
            #expect(throws: EstateCatalogError.invalidName(bad)) { try catalog.register(name: bad, directory: external) }
        }
        #expect(catalog.records.count == 2)
    }

    @Test func relocateRenameActivateRemoveEachSave() throws {
        let data = try configuration()
        defer { try? FileManager.default.removeItem(at: data); EstateCatalog.configurationDirectoryOverride = nil }
        var catalog = try EstateCatalog.create()
        try catalog.register(name: "research", directory: data.appendingPathComponent("databases/research"))

        let moved = URL(fileURLWithPath: "/Volumes/big/research", isDirectory: true)
        try catalog.relocate(name: "research", to: moved)
        #expect(try EstateCatalog.load().record(named: "research")?.directory == moved)
        #expect(throws: EstateCatalogError.unknownName("nope")) { try catalog.relocate(name: "nope", to: moved) }

        try catalog.rename("research", to: "lab")
        #expect(try EstateCatalog.load().records.map(\.name) == ["default", "lab"])
        #expect(catalog.record(named: "lab")?.directory == moved)
        #expect(throws: EstateCatalogError.duplicateName("default")) { try catalog.rename("lab", to: "default") }
        #expect(throws: EstateCatalogError.invalidName("a/b")) { try catalog.rename("lab", to: "a/b") }
        #expect(throws: EstateCatalogError.unknownName("nope")) { try catalog.rename("nope", to: "x") }

        try catalog.activate(name: "lab")
        #expect(try EstateCatalog.load().active.name == "lab")
        #expect(catalog.records.map(\.name) == ["lab", "default"])
        #expect(throws: EstateCatalogError.unknownName("nope")) { try catalog.activate(name: "nope") }

        try catalog.remove(name: "default")
        #expect(try EstateCatalog.load().records.map(\.name) == ["lab"])
        #expect(throws: EstateCatalogError.unknownName("default")) { try catalog.remove(name: "default") }
    }

    @Test func removeRefusesTheActiveRecord() throws {
        let data = try configuration()
        defer { try? FileManager.default.removeItem(at: data); EstateCatalog.configurationDirectoryOverride = nil }
        var catalog = try EstateCatalog.create()
        #expect(throws: EstateCatalogError.cannotRemoveActive("default")) { try catalog.remove(name: "default") }
        #expect(catalog.records.count == 1)
    }

    @Test func recordSpellsEveryOwnedFile() {
        let dir = URL(fileURLWithPath: "/tmp/x/databases/default", isDirectory: true)
        let record = EstateRecord(name: "default", directory: dir)
        #expect(record.ownedFileURLs.map(\.lastPathComponent) == [
            "estate.json", "estate.pid",
            "estate.sqlite", "estate.sqlite-wal", "estate.sqlite-shm",
            "estate.queue.sqlite", "estate.queue.sqlite-wal", "estate.queue.sqlite-shm",
            "estate.vectors.vec", "encode.drain.lease",
        ])
        #expect(record.legacyEncryptionOptOutURL.lastPathComponent == "no-encrypt")
        #expect(EstateCatalogNames.catalogFile == "estatecatalog.json")
        #expect(EstateCatalogNames.databasesFolder == "databases")
        #expect(EstateCatalogNames.defaultEstate == "default")
        #expect(record.ownedFileURLs.allSatisfy { $0.deletingLastPathComponent() == dir.standardizedFileURL })
    }

    @Test func selectorSplitsValueIntoPathAndName() throws {
        let bare = try EstateCatalog.EstateSelector("research")
        #expect(bare.name == "research" && bare.path == nil && bare.directory == nil)
        let abs = try EstateCatalog.EstateSelector("/Volumes/big/research")
        #expect(abs.name == "research")
        #expect(abs.path == URL(fileURLWithPath: "/Volumes/big", isDirectory: true))
        #expect(abs.directory == URL(fileURLWithPath: "/Volumes/big/research", isDirectory: true))
        let rel = try EstateCatalog.EstateSelector("sets/estate_set1/u7")
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        #expect(rel.directory == cwd.appendingPathComponent("sets/estate_set1/u7", isDirectory: true).standardizedFileURL)
        let trailing = try EstateCatalog.EstateSelector("/Volumes/big/research/")
        #expect(trailing == abs)
        let home = try EstateCatalog.EstateSelector("~/moot/x")
        #expect(home.directory?.path.hasSuffix("/moot/x") == true && home.directory?.path.hasPrefix("/") == true)
        for bad in ["", "/", "a/..", "./."] {
            #expect(throws: EstateCatalogError.invalidName(bad)) { _ = try EstateCatalog.EstateSelector(bad) }
        }
    }

    @Test func dbValueSelectsRegisteredOrAttachesTransient() throws {
        let data = try configuration()
        defer { try? FileManager.default.removeItem(at: data); EstateCatalog.configurationDirectoryOverride = nil }
        var catalog = try EstateCatalog.create()
        try catalog.register(name: "research", directory: URL(fileURLWithPath: "/Volumes/big/research", isDirectory: true))

        // Registered name: selected, made active, kind registered.
        let byName = try EstateCatalog.open(selecting: "research")
        #expect(byName.active.name == "research" && byName.active.kind == .registered)
        #expect(byName.records.map(\.name) == ["research", "default"])

        // Unregistered with a path: transient attach at path/name, active, not saved.
        let attached = try EstateCatalog.open(selecting: "/Volumes/tmp/scratch7")
        #expect(attached.active == EstateRecord(name: "scratch7",
                                                directory: URL(fileURLWithPath: "/Volumes/tmp/scratch7", isDirectory: true),
                                                kind: .transient))
        #expect(attached.records.count == 3)
        #expect(try EstateCatalog.load().records.count == 2)

        // A mutation while a transient is active still never writes it.
        var live = attached
        try live.register(name: "another", directory: data.appendingPathComponent("databases/another"))
        #expect(try EstateCatalog.load().records.map(\.name) == ["default", "research", "another"])

        // Unregistered without a path: format error.
        #expect(throws: EstateCatalogError.unregisteredWithoutPath("nowhere")) {
            _ = try EstateCatalog.open(selecting: "nowhere")
        }
        // Explicit path wins even when the name is registered: transient at that path.
        let explicit = try EstateCatalog.open(selecting: "/elsewhere/research")
        #expect(explicit.active.kind == .transient)
        #expect(explicit.active.directory == URL(fileURLWithPath: "/elsewhere/research", isDirectory: true))
        // The selector argument re-selects the same record in a child process.
        #expect(byName.active.selectorArgument == "research")
        #expect(attached.active.selectorArgument == "/Volumes/tmp/scratch7")
        #expect(try EstateCatalog.open(selecting: attached.active.selectorArgument).active == attached.active)
    }

    @Test func registerFromValueLandsWhereDbWouldLook() throws {
        let data = try configuration()
        defer { try? FileManager.default.removeItem(at: data); EstateCatalog.configurationDirectoryOverride = nil }
        var catalog = try EstateCatalog.create()
        try catalog.register("research")
        #expect(catalog.record(named: "research")?.directory == catalog.directory(forBareName: "research"))
        #expect(catalog.record(named: "research")?.directory.path == data.standardizedFileURL.path + "/databases/research")
        try catalog.register("/Volumes/big/lab")
        #expect(catalog.record(named: "lab")?.directory == URL(fileURLWithPath: "/Volumes/big/lab", isDirectory: true))
        #expect(try EstateCatalog.open(selecting: "lab").active.kind == .registered)
        #expect(throws: EstateCatalogError.duplicateName("lab")) { try catalog.register("/other/lab") }
    }

    @Test func moveDefaultRefusesInThisVersion() throws {
        let data = try configuration()
        defer { try? FileManager.default.removeItem(at: data); EstateCatalog.configurationDirectoryOverride = nil }
        var catalog = try EstateCatalog.create()
        let before = try file(data)
        #expect(throws: EstateCatalogError.notAvailableInThisVersion(operation: "moveDefault")) {
            try catalog.moveDefault(to: URL(fileURLWithPath: "/Volumes/big/moot", isDirectory: true))
        }
        #expect(try file(data) == before)
        #expect(catalog.defaultLocation == EstateCatalog.initialDefaultLocation)
    }

    @Test func estateManifestRoundTripsInsideTheEstateDirectory() throws {
        let data = try configuration()
        defer { try? FileManager.default.removeItem(at: data); EstateCatalog.configurationDirectoryOverride = nil }
        let record = EstateRecord(name: "barnone", directory: data.appendingPathComponent("foo/bar/barnone"), kind: .transient)
        let written = EstateManifest(name: "barnone", schemaVersion: GeniusLocusKitSchema.version,
                                          formatVersion: .current, encryption: .plaintext,
                                          created: "2026-09-08T00:00:00Z")
        try EstateCatalog.writeManifest(written, to: record)
        #expect(FileManager.default.fileExists(atPath: record.manifestURL.path))
        #expect(record.manifestURL.path.hasSuffix("/foo/bar/barnone/estate.json"))
        let read = try EstateCatalog.readManifest(of: record)
        #expect(read == written)
        #expect(read.fileVersion == EstateManifest.currentFileVersion)
        #expect(read.formatVersion == .v1_7)
        // Nothing else appears in the estate directory or its parent.
        #expect(try FileManager.default.contentsOfDirectory(atPath: record.directory.path) == ["estate.json"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: record.directory.deletingLastPathComponent().path) == ["barnone"])
    }

    @Test func estateManifestRefusesMissingForeignAndRenamed() throws {
        let data = try configuration()
        defer { try? FileManager.default.removeItem(at: data); EstateCatalog.configurationDirectoryOverride = nil }
        let record = EstateRecord(name: "a", directory: data.appendingPathComponent("a"))
        var thrown: EstateCatalogError?
        do { _ = try EstateCatalog.readManifest(of: record) } catch let e as EstateCatalogError { thrown = e }
        guard case .unreadableEstateManifest? = thrown else { Issue.record("missing: \(String(describing: thrown))"); return }
        // Written for one name, read through a record of another: refused both ways.
        let cfg = EstateManifest(name: "a", schemaVersion: 1, formatVersion: .current,
                                      encryption: .encrypted, created: "2026-09-08T00:00:00Z")
        try EstateCatalog.writeManifest(cfg, to: record)
        let renamed = EstateRecord(name: "b", directory: record.directory)
        thrown = nil
        do { _ = try EstateCatalog.readManifest(of: renamed) } catch let e as EstateCatalogError { thrown = e }
        guard case .unreadableEstateManifest? = thrown else { Issue.record("renamed: \(String(describing: thrown))"); return }
        thrown = nil
        do { try EstateCatalog.writeManifest(cfg, to: renamed) } catch let e as EstateCatalogError { thrown = e }
        guard case .unreadableEstateManifest? = thrown else { Issue.record("foreign write: \(String(describing: thrown))"); return }
    }

    @Test func transientAttachRefusesARogueManifest() throws {
        let data = try configuration()
        defer { try? FileManager.default.removeItem(at: data); EstateCatalog.configurationDirectoryOverride = nil }
        _ = try EstateCatalog.create()
        let dir = data.appendingPathComponent("tmp/scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifestURL = dir.appendingPathComponent("estate.json")

        // A manifest for a different estate: refused.
        try #"{"fileVersion":1,"name":"other","schemaVersion":1,"formatVersion":{"major":1,"minor":7},"encryption":"plaintext","created":"2026-09-08T00:00:00Z"}"#
            .write(to: manifestURL, atomically: true, encoding: .utf8)
        var thrown: EstateCatalogError?
        do { _ = try EstateCatalog.open(selecting: dir.path) } catch let e as EstateCatalogError { thrown = e }
        guard case .unreadableEstateManifest? = thrown else { Issue.record("other name: \(String(describing: thrown))"); return }

        // The right name but an extra key that could redirect: refused.
        try #"{"fileVersion":1,"name":"scratch","schemaVersion":1,"formatVersion":{"major":1,"minor":7},"encryption":"plaintext","created":"2026-09-08T00:00:00Z","path":"/elsewhere"}"#
            .write(to: manifestURL, atomically: true, encoding: .utf8)
        thrown = nil
        do { _ = try EstateCatalog.open(selecting: dir.path) } catch let e as EstateCatalogError { thrown = e }
        guard case .unreadableEstateManifest(_, let detail)? = thrown, detail.contains("path") else {
            Issue.record("extra key: \(String(describing: thrown))"); return
        }

        // A correct manifest: attached.
        try #"{"fileVersion":1,"name":"scratch","schemaVersion":1,"formatVersion":{"major":1,"minor":7},"encryption":"plaintext","created":"2026-09-08T00:00:00Z"}"#
            .write(to: manifestURL, atomically: true, encoding: .utf8)
        #expect(try EstateCatalog.open(selecting: dir.path).active.name == "scratch")

        // A database that is a symlink to somewhere else: refused, manifest or not.
        let elsewhere = data.appendingPathComponent("elsewhere.sqlite")
        try Data("x".utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("estate.sqlite"), withDestinationURL: elsewhere)
        thrown = nil
        do { _ = try EstateCatalog.open(selecting: dir.path) } catch let e as EstateCatalogError { thrown = e }
        guard case .unreadableEstateManifest(_, let symlinkDetail)? = thrown, symlinkDetail.contains("symbolic link") else {
            Issue.record("symlink: \(String(describing: thrown))"); return
        }
        try FileManager.default.removeItem(at: manifestURL)
        thrown = nil
        do { _ = try EstateCatalog.open(selecting: dir.path) } catch let e as EstateCatalogError { thrown = e }
        guard case .unreadableEstateManifest? = thrown else { Issue.record("symlink without manifest: \(String(describing: thrown))"); return }
    }

    @Test func backendRoundTripsAndDefaultsToSQLite() throws {
        let data = try configuration()
        defer { try? FileManager.default.removeItem(at: data); EstateCatalog.configurationDirectoryOverride = nil }
        var catalog = try EstateCatalog.create()
        #expect(catalog.active.backend == .sqlite)
        let connection = "postgresql://moot@db.example/estates"
        try catalog.register(name: "pg", directory: data.appendingPathComponent("databases/pg"),
                             backend: .postgresql(connectionString: connection))
        // The file spells the backend only when it is not SQLite; the default record has no field.
        let entries = try fileEntries(data)
        #expect(entries[0].backend == nil)
        #expect(entries[1].backend == .postgresql(connectionString: connection))
        let text = try String(contentsOf: EstateCatalog.catalogURL, encoding: .utf8)
        #expect(text.contains(#""kind" : "postgresql""#))
        #expect(text.contains(#""connectionString" : "postgresql:\/\/moot@db.example\/estates""#))   // JSONEncoder escapes "/"
        // Reload, rename and relocate keep the backend.
        var loaded = try EstateCatalog.load()
        #expect(loaded.record(named: "pg")?.backend == .postgresql(connectionString: connection))
        try loaded.rename("pg", to: "warehouse")
        try loaded.relocate(name: "warehouse", to: data.appendingPathComponent("elsewhere/warehouse"))
        #expect(try EstateCatalog.load().record(named: "warehouse")?.backend == .postgresql(connectionString: connection))
        // A transient attach is always SQLite.
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try EstateCatalog.open(selecting: dir.path).active.backend == .sqlite)
    }

    @Test func loadRefusesAMalformedBackendEntry() throws {
        let data = try configuration()
        defer { try? FileManager.default.removeItem(at: data); EstateCatalog.configurationDirectoryOverride = nil }
        let url = EstateCatalog.catalogURL
        for entry in [
            #"{"name": "default", "path": "/x", "backend": {"kind": "postgresql"}}"#,
            #"{"name": "default", "path": "/x", "backend": {"kind": "postgresql", "connectionString": ""}}"#,
            #"{"name": "default", "path": "/x", "backend": {"kind": "sqlite", "connectionString": "postgresql://h/d"}}"#,
            #"{"name": "default", "path": "/x", "backend": {"kind": "oracle"}}"#,
        ] {
            try #"{"version": 1, "defaultLocation": "/d", "estates": [\#(entry)]}"#.write(to: url, atomically: true, encoding: .utf8)
            var thrown: EstateCatalogError?
            do { _ = try EstateCatalog.load() } catch let e as EstateCatalogError { thrown = e }
            guard case .unreadableCatalog? = thrown else { Issue.record("\(entry): \(String(describing: thrown))"); return }
        }
        // The explicit SQLite spelling is accepted.
        try #"{"version": 1, "defaultLocation": "/d", "estates": [{"name": "default", "path": "/x", "backend": {"kind": "sqlite"}}]}"#.write(to: url, atomically: true, encoding: .utf8)
        #expect(try EstateCatalog.load().active.backend == .sqlite)
    }

    @Test func theCatalogNeverTouchesEstateFiles() throws {
        let data = try configuration()
        defer { try? FileManager.default.removeItem(at: data); EstateCatalog.configurationDirectoryOverride = nil }
        var catalog = try EstateCatalog.create()
        try catalog.register(name: "r", directory: data.appendingPathComponent("databases/r"))
        try catalog.relocate(name: "r", to: data.appendingPathComponent("elsewhere/r"))
        try catalog.activate(name: "r")
        try catalog.remove(name: "default")
        // Only estatecatalog.json exists under the configuration directory: no databases/, no elsewhere/.
        let contents = try FileManager.default.contentsOfDirectory(atPath: data.path)
        #expect(contents == [EstateCatalog.fileName])
    }
}
