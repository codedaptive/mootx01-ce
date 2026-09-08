#if GLK_MIGRATION_APP_CONTAINER_TO_CATALOG

// AppContainerLayoutMigrationTests.swift
//
// Verifies the app-container → catalog-layout capsule over temporary
// directories: nothing to move on a clean container, a full move that renames
// mootx01.sqlite and its WAL/SHM to the catalog's names with the main
// database last, a partial set moving only what exists, refusal when both
// layouts hold a database, a non-default or transient record left alone,
// resumption after an interrupted move, the key hook running before the
// database moves (and never on a refusal or after a hook failure), and the
// emptied legacy folder being removed while a folder with other content stays.
//
// The tests that take the default hook probe the Keychain read-only for
// accounts no estate has; nothing is minted.

import Foundation
import GeniusLocusKit
import GLKMigrationAppContainerToCatalog
import Testing

@Suite("AppContainerLayoutMigration")
struct AppContainerLayoutMigrationTests {

    private func makeContainer() throws -> (support: URL, configuration: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-container-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("Library/Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return (support, support.appendingPathComponent(EstateCatalog.productIdentifier, isDirectory: true))
    }

    private func defaultRecord(configuration: URL) -> EstateRecord {
        EstateRecord(
            name: EstateCatalog.defaultName,
            directory: configuration
                .appendingPathComponent(EstateCatalogNames.databasesFolder, isDirectory: true)
                .appendingPathComponent(EstateCatalog.defaultName, isDirectory: true))
    }

    private func legacyDirectory(_ support: URL) -> URL {
        support.appendingPathComponent(AppContainerLayoutMigration.legacyFolder, isDirectory: true)
    }

    private func write(_ names: [String], in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in names {
            try Data(name.utf8).write(to: directory.appendingPathComponent(name, isDirectory: false))
        }
    }

    private func exists(_ name: String, in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
    }

    @Test("A clean container has nothing to move and is not pending")
    func cleanContainerIsNoOp() throws {
        let (support, configuration) = try makeContainer()
        let record = defaultRecord(configuration: configuration)
        #expect(!AppContainerLayoutMigration.pending(applicationSupportDirectory: support, record: record))
        #expect(try AppContainerLayoutMigration.run(applicationSupportDirectory: support, into: record) == .nothingToMove)
        #expect(!FileManager.default.fileExists(atPath: record.directory.path))
    }

    @Test("The legacy database and its WAL/SHM move under the catalog's names, the database last, and the empty folder goes")
    func fullSetMovesAndRenames() throws {
        let (support, configuration) = try makeContainer()
        let record = defaultRecord(configuration: configuration)
        let legacy = legacyDirectory(support)
        try write(["mootx01.sqlite", "mootx01.sqlite-wal", "mootx01.sqlite-shm"], in: legacy)
        #expect(AppContainerLayoutMigration.legacyDatabaseURL(applicationSupportDirectory: support)
                == legacy.appendingPathComponent("mootx01.sqlite", isDirectory: false))
        #expect(AppContainerLayoutMigration.pending(applicationSupportDirectory: support, record: record))

        let outcome = try AppContainerLayoutMigration.run(applicationSupportDirectory: support, into: record)
        #expect(outcome == .moved(files: ["mootx01.sqlite-wal", "mootx01.sqlite-shm", "mootx01.sqlite"]))
        #expect(exists(EstateCatalogNames.database, in: record.directory))
        #expect(exists(EstateCatalogNames.databaseWAL, in: record.directory))
        #expect(exists(EstateCatalogNames.databaseSHM, in: record.directory))
        #expect(try Data(contentsOf: record.databaseURL) == Data("mootx01.sqlite".utf8), "the same bytes under the new name")
        #expect(!FileManager.default.fileExists(atPath: legacy.path), "the emptied legacy folder is removed")
        // Second run: migrated, nothing pending.
        #expect(!AppContainerLayoutMigration.pending(applicationSupportDirectory: support, record: record))
        #expect(try AppContainerLayoutMigration.run(applicationSupportDirectory: support, into: record) == .nothingToMove)
    }

    @Test("Only the files present move; a folder holding anything else stays")
    func partialSetMovesWhatExistsAndKeepsAFullFolder() throws {
        let (support, configuration) = try makeContainer()
        let record = defaultRecord(configuration: configuration)
        let legacy = legacyDirectory(support)
        try write(["mootx01.sqlite", "notes.txt"], in: legacy)
        let outcome = try AppContainerLayoutMigration.run(applicationSupportDirectory: support, into: record)
        #expect(outcome == .moved(files: ["mootx01.sqlite"]))
        #expect(!exists(EstateCatalogNames.databaseWAL, in: record.directory))
        #expect(exists("notes.txt", in: legacy), "a file the capsule does not know is left where it was")
        #expect(FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test("Both layouts holding a database is refused and nothing is touched")
    func bothPresentRefuses() throws {
        let (support, configuration) = try makeContainer()
        let record = defaultRecord(configuration: configuration)
        let legacy = legacyDirectory(support)
        try write(["mootx01.sqlite", "mootx01.sqlite-wal"], in: legacy)
        try write([EstateCatalogNames.database], in: record.directory)
        var hookCalls = 0
        let outcome = try AppContainerLayoutMigration.run(applicationSupportDirectory: support, into: record) { _, _ in
            hookCalls += 1; return true
        }
        #expect(outcome == .refused(
            legacy: legacy.appendingPathComponent("mootx01.sqlite", isDirectory: false),
            catalog: record.databaseURL))
        #expect(hookCalls == 0, "a refusal never touches the key")
        #expect(exists("mootx01.sqlite", in: legacy))
        #expect(exists("mootx01.sqlite-wal", in: legacy))
        #expect(!exists(EstateCatalogNames.databaseWAL, in: record.directory))
        #expect(AppContainerLayoutMigration.pending(applicationSupportDirectory: support, record: record))
    }

    @Test("A non-default or transient record is never the target of the legacy estate")
    func otherRecordsAreLeftAlone() throws {
        let (support, configuration) = try makeContainer()
        let legacy = legacyDirectory(support)
        try write(["mootx01.sqlite"], in: legacy)
        let named = EstateRecord(name: "research", directory: configuration.appendingPathComponent("databases/research"))
        let transient = EstateRecord(name: EstateCatalog.defaultName,
                                     directory: configuration.appendingPathComponent("elsewhere/default"),
                                     kind: .transient)
        for record in [named, transient] {
            #expect(!AppContainerLayoutMigration.pending(applicationSupportDirectory: support, record: record))
            #expect(try AppContainerLayoutMigration.run(applicationSupportDirectory: support, into: record) == .nothingToMove)
        }
        #expect(exists("mootx01.sqlite", in: legacy))
    }

    @Test("The key moves to the new path's account before the database does; a hook failure moves no file")
    func keyRelocatesBeforeTheDatabaseMoves() throws {
        let (support, configuration) = try makeContainer()
        let record = defaultRecord(configuration: configuration)
        let legacy = legacyDirectory(support)
        try write(["mootx01.sqlite", "mootx01.sqlite-wal"], in: legacy)
        var calls: [(from: URL, to: URL, databaseStillLegacy: Bool)] = []
        let outcome = try AppContainerLayoutMigration.run(applicationSupportDirectory: support, into: record) { from, to in
            calls.append((from, to, self.exists("mootx01.sqlite", in: legacy)))
            return true
        }
        guard case .moved = outcome else { Issue.record("expected .moved, got \(outcome)"); return }
        #expect(calls.count == 1)
        #expect(calls.first?.from == legacy.appendingPathComponent("mootx01.sqlite", isDirectory: false))
        #expect(calls.first?.to == record.databaseURL)
        #expect(calls.first?.databaseStillLegacy == true, "the key must be in place before the file leaves")

        let (support2, configuration2) = try makeContainer()
        let record2 = defaultRecord(configuration: configuration2)
        let legacy2 = legacyDirectory(support2)
        try write(["mootx01.sqlite", "mootx01.sqlite-wal"], in: legacy2)
        struct KeyFailure: Error {}
        #expect(throws: KeyFailure.self) {
            try AppContainerLayoutMigration.run(applicationSupportDirectory: support2, into: record2) { _, _ in throw KeyFailure() }
        }
        #expect(exists("mootx01.sqlite", in: legacy2))
        #expect(exists("mootx01.sqlite-wal", in: legacy2))
        #expect(!exists(EstateCatalogNames.databaseWAL, in: record2.directory))
    }

    @Test("An interrupted move resumes: sidecars already across are skipped, the database completes it")
    func interruptedMoveResumes() throws {
        let (support, configuration) = try makeContainer()
        let record = defaultRecord(configuration: configuration)
        let legacy = legacyDirectory(support)
        // The crash landed after the WAL moved but before the main database did.
        try write(["mootx01.sqlite", "mootx01.sqlite-shm"], in: legacy)
        try write([EstateCatalogNames.databaseWAL], in: record.directory)
        #expect(AppContainerLayoutMigration.pending(applicationSupportDirectory: support, record: record))
        let outcome = try AppContainerLayoutMigration.run(applicationSupportDirectory: support, into: record)
        #expect(outcome == .moved(files: ["mootx01.sqlite-shm", "mootx01.sqlite"]))
        for name in [EstateCatalogNames.database, EstateCatalogNames.databaseWAL, EstateCatalogNames.databaseSHM] {
            #expect(exists(name, in: record.directory), "\(name) at destination")
        }
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }
}

#endif
