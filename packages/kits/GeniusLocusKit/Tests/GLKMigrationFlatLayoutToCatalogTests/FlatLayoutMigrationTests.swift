#if GLK_MIGRATION_FLAT_LAYOUT_TO_CATALOG

// FlatLayoutMigrationTests.swift
//
// Verifies the flat-layout → catalog-layout capsule over temporary
// directories: nothing to move on a clean directory, a full move of every
// owned file including the legacy no-encrypt marker, a partial set (no WAL
// or SHM present) moving only what exists, refusal when both layouts hold a
// database, a non-default or transient record left alone, resumption
// after an interrupted move that already carried some siblings across, and
// the key relocation hook running before the database moves (and not at
// all when the capsule refuses).
//
// The tests that take the default hook probe the Keychain read-only for
// accounts no estate has; nothing is minted.

import Foundation
import GeniusLocusKit
import GLKMigrationFlatLayoutToCatalog
import Testing

@Suite("FlatLayoutMigration")
struct FlatLayoutMigrationTests {

    private func makeConfigurationDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flat-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func defaultRecord(in configuration: URL) -> EstateRecord {
        EstateRecord(
            name: EstateCatalog.defaultName,
            directory: configuration
                .appendingPathComponent(EstateCatalogNames.databasesFolder, isDirectory: true)
                .appendingPathComponent(EstateCatalog.defaultName, isDirectory: true))
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

    @Test("A clean configuration directory has nothing to move and is not pending")
    func cleanDirectoryIsNoOp() throws {
        let configuration = try makeConfigurationDirectory()
        let record = defaultRecord(in: configuration)
        #expect(!FlatLayoutMigration.pending(configurationDirectory: configuration, record: record))
        #expect(try FlatLayoutMigration.run(configurationDirectory: configuration, into: record) == .nothingToMove)
        #expect(!FileManager.default.fileExists(atPath: record.directory.path))
    }

    @Test("Every flat file the estate owns, and the legacy marker, moves into the record's directory")
    func fullSetMoves() throws {
        let configuration = try makeConfigurationDirectory()
        let record = defaultRecord(in: configuration)
        let names = [
            EstateCatalogNames.database, EstateCatalogNames.databaseWAL, EstateCatalogNames.databaseSHM,
            EstateCatalogNames.queue, EstateCatalogNames.queueWAL, EstateCatalogNames.queueSHM,
            EstateCatalogNames.vectors, EstateCatalogNames.drainLease,
            EstateCatalogNames.legacyEncryptionOptOut,
        ]
        try write(names + ["daemon.port"], in: configuration)
        #expect(FlatLayoutMigration.pending(configurationDirectory: configuration, record: record))

        let outcome = try FlatLayoutMigration.run(configurationDirectory: configuration, into: record)
        guard case .moved(let moved) = outcome else {
            Issue.record("expected .moved, got \(outcome)")
            return
        }
        #expect(Set(moved) == Set(names))
        #expect(moved.last == EstateCatalogNames.database, "the main database moves last")
        for name in names {
            #expect(exists(name, in: record.directory), "\(name) at destination")
            #expect(!exists(name, in: configuration), "\(name) gone from source")
        }
        // A configuration file that is not an estate file stays where it was.
        #expect(exists("daemon.port", in: configuration))
        // The moved database is the same bytes.
        #expect(try Data(contentsOf: record.databaseURL) == Data(EstateCatalogNames.database.utf8))
        // Second run: migrated, nothing pending.
        #expect(!FlatLayoutMigration.pending(configurationDirectory: configuration, record: record))
        #expect(try FlatLayoutMigration.run(configurationDirectory: configuration, into: record) == .nothingToMove)
    }

    @Test("Only the files present move; a clean-closed estate has no WAL or SHM")
    func partialSetMovesWhatExists() throws {
        let configuration = try makeConfigurationDirectory()
        let record = defaultRecord(in: configuration)
        try write([EstateCatalogNames.database, EstateCatalogNames.vectors], in: configuration)
        let outcome = try FlatLayoutMigration.run(configurationDirectory: configuration, into: record)
        #expect(outcome == .moved(files: [EstateCatalogNames.vectors, EstateCatalogNames.database]))
        #expect(!exists(EstateCatalogNames.databaseWAL, in: record.directory))
    }

    @Test("Both layouts holding a database is refused and nothing is touched")
    func bothPresentRefuses() throws {
        let configuration = try makeConfigurationDirectory()
        let record = defaultRecord(in: configuration)
        try write([EstateCatalogNames.database, EstateCatalogNames.vectors], in: configuration)
        try write([EstateCatalogNames.database], in: record.directory)
        let outcome = try FlatLayoutMigration.run(configurationDirectory: configuration, into: record)
        #expect(outcome == .refused(
            flat: configuration.appendingPathComponent(EstateCatalogNames.database, isDirectory: false),
            catalog: record.databaseURL))
        #expect(exists(EstateCatalogNames.database, in: configuration))
        #expect(exists(EstateCatalogNames.vectors, in: configuration))
        #expect(!exists(EstateCatalogNames.vectors, in: record.directory))
        // Still pending: the operator has not resolved it.
        #expect(FlatLayoutMigration.pending(configurationDirectory: configuration, record: record))
    }

    @Test("A non-default or transient record is never the target of the flat estate")
    func otherRecordsAreLeftAlone() throws {
        let configuration = try makeConfigurationDirectory()
        try write([EstateCatalogNames.database], in: configuration)
        let named = EstateRecord(name: "research", directory: configuration.appendingPathComponent("databases/research"))
        let transient = EstateRecord(name: EstateCatalog.defaultName,
                                     directory: configuration.appendingPathComponent("elsewhere/default"),
                                     kind: .transient)
        for record in [named, transient] {
            #expect(!FlatLayoutMigration.pending(configurationDirectory: configuration, record: record))
            #expect(try FlatLayoutMigration.run(configurationDirectory: configuration, into: record) == .nothingToMove)
        }
        #expect(exists(EstateCatalogNames.database, in: configuration))
    }

    @Test("The key moves to the new path's account before the database does, and never on a refusal")
    func keyRelocatesBeforeTheDatabaseMoves() throws {
        let configuration = try makeConfigurationDirectory()
        let record = defaultRecord(in: configuration)
        try write([EstateCatalogNames.database, EstateCatalogNames.vectors], in: configuration)
        var calls: [(from: URL, to: URL, databaseStillFlat: Bool)] = []
        let outcome = try FlatLayoutMigration.run(configurationDirectory: configuration, into: record) { from, to in
            calls.append((from, to, self.exists(EstateCatalogNames.database, in: configuration)))
            return true
        }
        guard case .moved = outcome else { Issue.record("expected .moved, got \(outcome)"); return }
        #expect(calls.count == 1)
        #expect(calls.first?.from == configuration.appendingPathComponent(EstateCatalogNames.database, isDirectory: false))
        #expect(calls.first?.to == record.databaseURL)
        #expect(calls.first?.databaseStillFlat == true, "the key must be in place before the file leaves")

        // A refusal never touches the key.
        let other = try makeConfigurationDirectory()
        let otherRecord = defaultRecord(in: other)
        try write([EstateCatalogNames.database], in: other)
        try write([EstateCatalogNames.database], in: otherRecord.directory)
        var refusedCalls = 0
        _ = try FlatLayoutMigration.run(configurationDirectory: other, into: otherRecord) { _, _ in refusedCalls += 1; return true }
        #expect(refusedCalls == 0)

        // A failing relocation stops the run before any file moves.
        let third = try makeConfigurationDirectory()
        let thirdRecord = defaultRecord(in: third)
        try write([EstateCatalogNames.database, EstateCatalogNames.vectors], in: third)
        struct KeyFailure: Error {}
        #expect(throws: KeyFailure.self) {
            try FlatLayoutMigration.run(configurationDirectory: third, into: thirdRecord) { _, _ in throw KeyFailure() }
        }
        #expect(exists(EstateCatalogNames.database, in: third))
        #expect(exists(EstateCatalogNames.vectors, in: third))
        #expect(!exists(EstateCatalogNames.vectors, in: thirdRecord.directory))
    }

    @Test("An interrupted move resumes: siblings already across are skipped, the database completes it")
    func interruptedMoveResumes() throws {
        let configuration = try makeConfigurationDirectory()
        let record = defaultRecord(in: configuration)
        // The crash landed after the vectors sidecar and the queue moved but
        // before the main database did.
        try write([EstateCatalogNames.database, EstateCatalogNames.databaseWAL], in: configuration)
        try write([EstateCatalogNames.vectors, EstateCatalogNames.queue], in: record.directory)
        #expect(FlatLayoutMigration.pending(configurationDirectory: configuration, record: record))
        let outcome = try FlatLayoutMigration.run(configurationDirectory: configuration, into: record)
        #expect(outcome == .moved(files: [EstateCatalogNames.databaseWAL, EstateCatalogNames.database]))
        for name in [EstateCatalogNames.database, EstateCatalogNames.databaseWAL,
                     EstateCatalogNames.vectors, EstateCatalogNames.queue] {
            #expect(exists(name, in: record.directory), "\(name) at destination")
        }
        #expect(!exists(EstateCatalogNames.database, in: configuration))
    }
}

#endif
