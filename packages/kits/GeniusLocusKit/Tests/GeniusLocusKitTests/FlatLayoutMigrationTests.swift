#if GLK_MIGRATION_FLAT_LAYOUT_TO_CATALOG

// FlatLayoutMigrationTests.swift
//
// Verifies the flat-layout → catalog-layout adoption over temporary
// directories: nothing to move on a clean directory, a full move of every
// owned file including the legacy no-encrypt marker, a partial set (no WAL
// or SHM present) moving only what exists, refusal when both layouts hold a
// database, a non-default or transient record left alone, resumption
// after an interrupted move that already carried some siblings across, the
// key relocation hook running before the database moves (and not at all
// when the move refuses), and the both-present reclaim: a catalog estate
// holding only the product's seeded charter hints is retired and the flat
// estate moved in, while one user drawer keeps the refusal.
//
// The open-level seam (the first `EstateCatalog.open()` adopts, an open that
// finds both layouts refuses) is pinned in EstateCatalogTests, the suite
// that owns the configuration-directory override.
//
// The tests that take the default hook probe the Keychain read-only for
// accounts no estate has; nothing is minted.

import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitSQLite
import SubstrateTypes
import Testing
@testable import GeniusLocusKit   // moveOrder, to pin the fixture against the move's list; seedDefaultWings

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
        // Every entry of `moveOrder`, including the manifest and PID marker a
        // pre-catalog build may have left, so the fixture covers the whole list.
        let names = [
            EstateCatalogNames.database, EstateCatalogNames.databaseWAL, EstateCatalogNames.databaseSHM,
            EstateCatalogNames.queue, EstateCatalogNames.queueWAL, EstateCatalogNames.queueSHM,
            EstateCatalogNames.vectors, EstateCatalogNames.drainLease,
            EstateCatalogNames.manifest, EstateCatalogNames.pid,
            EstateCatalogNames.legacyEncryptionOptOut,
        ]
        #expect(Set(names) == Set(FlatLayoutMigration.moveOrder), "the fixture names every file the capsule moves")
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

    // MARK: - The both-present reclaim

    /// A real plaintext LocusKit estate at the record's database path, seeded
    /// with the default wings' charter hints exactly as a registered serve
    /// seeds them, plus whatever `also` captures into it.
    private func seedCatalogEstate(at record: EstateRecord,
                                   also: ((GeniusLocusKit, EstateHandle) async throws -> Void)? = nil) async throws {
        try FileManager.default.createDirectory(at: record.directory, withIntermediateDirectories: true)
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .sqlite(url: record.databaseURL)))
        let owner = OwnerCredentials(ownerIdentifier: "flat-layout-tests")
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let kit = GeniusLocusKit()
        let handle = try await kit.open(storage: storage, owner: owner)
        try await kit.seedDefaultWings(for: handle, now: Date(timeIntervalSince1970: 1_700_000_000))
        try await also?(kit, handle)
        try await kit.close(handle)
        await storage.close()
    }

    @Test("A catalog estate holding only the seeded charter hints is retired, key and all, and the flat estate moves in")
    func reclaimRetiresACharterOnlyCatalogEstate() async throws {
        let configuration = try makeConfigurationDirectory()
        let record = defaultRecord(in: configuration)
        try write([EstateCatalogNames.database, EstateCatalogNames.vectors], in: configuration)
        try await seedCatalogEstate(at: record)
        #expect(try FlatLayoutMigration.run(configurationDirectory: configuration, into: record)
                == .refused(flat: configuration.appendingPathComponent(EstateCatalogNames.database, isDirectory: false),
                            catalog: record.databaseURL),
                "the synchronous move never resolves a both-present slot")

        var relocations = 0
        let outcome = try await FlatLayoutMigration.reclaimDefaultSlot(
            configurationDirectory: configuration, record: record, ownerIdentifier: "flat-layout-tests"
        ) { _, _ in relocations += 1; return false }
        guard case .reclaimed(let retired, let moved) = outcome else {
            Issue.record("expected .reclaimed, got \(outcome)")
            return
        }
        #expect(retired.contains(EstateCatalogNames.database))
        #expect(Set(moved) == [EstateCatalogNames.vectors, EstateCatalogNames.database])
        #expect(relocations == 1, "the flat estate's key is relocated after the catalog estate's key is disposed")
        // The adopted database is the flat one, byte for byte.
        #expect(try Data(contentsOf: record.databaseURL) == Data(EstateCatalogNames.database.utf8))
        #expect(exists(EstateCatalogNames.vectors, in: record.directory))
        #expect(!exists(EstateCatalogNames.database, in: configuration))
        #expect(!FlatLayoutMigration.pending(configurationDirectory: configuration, record: record))
    }

    @Test("One drawer the product did not seed keeps the refusal and nothing is touched")
    func reclaimRefusesUserContent() async throws {
        let configuration = try makeConfigurationDirectory()
        let record = defaultRecord(in: configuration)
        try write([EstateCatalogNames.database, EstateCatalogNames.vectors], in: configuration)
        try await seedCatalogEstate(at: record) { kit, handle in
            _ = try await kit.captureBatch(handle, [CaptureFrame(
                content: "a note the user wrote", channel: .typed, room: "notes",
                latticeAnchor: .udc("000"), addedBy: "the-user", embeddingModelID: "test-model-v1")])
        }

        var relocations = 0
        let outcome = try await FlatLayoutMigration.reclaimDefaultSlot(
            configurationDirectory: configuration, record: record, ownerIdentifier: "flat-layout-tests"
        ) { _, _ in relocations += 1; return false }
        guard case .refused(let flat, let catalog, let reason) = outcome else {
            Issue.record("expected .refused, got \(outcome)")
            return
        }
        #expect(flat == configuration.appendingPathComponent(EstateCatalogNames.database, isDirectory: false))
        #expect(catalog == record.databaseURL)
        guard case .userContent = reason else { Issue.record("expected a user-content refusal, got \(reason)"); return }
        #expect(relocations == 0)
        // The catalog estate still holds the user's drawer beside the charters
        // (the check's own open leaves bookkeeping in the file; the content is
        // what must survive).
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .sqlite(url: record.databaseURL)))
        let estate = try await LocusKit.Estate.open(
            storage: storage, owner: OwnerCredentials(ownerIdentifier: "flat-layout-tests"))
        let drawers = try await estate.allDrawers()
        try await estate.close()
        await storage.close()
        #expect(drawers.count == LocusKit.defaultWings.count + 1)
        #expect(drawers.contains { $0.addedBy == "the-user" }, "the catalog estate is untouched")
        #expect(exists(EstateCatalogNames.database, in: configuration))
        #expect(exists(EstateCatalogNames.vectors, in: configuration))
        #expect(!exists(EstateCatalogNames.vectors, in: record.directory))
    }

    @Test("A catalog estate that cannot be opened is a refusal, never a retirement")
    func reclaimRefusesAnUnreadableCatalogEstate() async throws {
        let configuration = try makeConfigurationDirectory()
        let record = defaultRecord(in: configuration)
        try write([EstateCatalogNames.database], in: configuration)
        // Not a database at all: the open fails and the check cannot prove anything.
        try write([EstateCatalogNames.database], in: record.directory)
        let outcome = try await FlatLayoutMigration.reclaimDefaultSlot(
            configurationDirectory: configuration, record: record, ownerIdentifier: "flat-layout-tests"
        ) { _, _ in false }
        guard case .refused(_, _, let reason) = outcome, case .unreadable = reason else {
            Issue.record("expected an unreadable refusal, got \(outcome)")
            return
        }
        #expect(try Data(contentsOf: record.databaseURL) == Data(EstateCatalogNames.database.utf8))
        #expect(exists(EstateCatalogNames.database, in: configuration))
    }
}

#endif
