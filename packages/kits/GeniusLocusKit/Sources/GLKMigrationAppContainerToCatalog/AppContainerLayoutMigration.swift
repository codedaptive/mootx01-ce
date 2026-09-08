// App-container layout → catalog-layout migration capsule.
//
// Root cause of this capsule's existence: every pre-catalog Apple app build
// (macOS and iOS) kept its one estate at
// `<Application Support>/mootx01/mootx01.sqlite` inside the app's container,
// a path the app computed itself. The estate catalog places the same estate
// at `<configuration>/databases/default/estate.sqlite`, where the
// configuration directory is the catalog's, computed from the same container
// home. An app updated across that line holds a populated estate under the
// old name that no catalog record names; without this capsule the first
// catalog open would create an empty default estate and the user's memory
// would appear to vanish. The app runs this before its first open of the
// registered default record.
//
// What the capsule does:
//   1. Looks for the legacy database at `<Application Support>/mootx01/
//      mootx01.sqlite`. Absent means nothing to do: a fresh install, or an
//      app already migrated.
//   2. Refuses when the legacy database AND the record's database both
//      exist. Two estates claiming the default slot is the user's decision,
//      never a guess; nothing is touched.
//   3. Otherwise moves the estate's Keychain key to the account of the new
//      database path (`EstateOpenPosture.relocateKey`): the key is looked up
//      by a hash of the file's path, so an encrypted estate moved without
//      its key would fail closed on its next open. The key goes first so an
//      interrupted run resumes with the key already in place.
//   4. Then renames the legacy files into the record's directory under the
//      catalog's names: `mootx01.sqlite-wal` → `estate.sqlite-wal`,
//      `mootx01.sqlite-shm` → `estate.sqlite-shm`, and the main database
//      LAST (`mootx01.sqlite` → `estate.sqlite`). Same volume, so each
//      rename is atomic and no bytes are copied. The pre-catalog app never
//      wired a queue or a vector sidecar, so these three are the whole estate.
//   5. Removes the legacy `mootx01` folder if it is now empty. Best effort;
//      a folder holding anything else is left alone.
//
// Why the main database moves last: a crash mid-move leaves the legacy
// database in place with its sidecars already across. The next run sees the
// legacy database present and the record's database absent, so it resumes,
// skipping every sidecar no longer at the source, and finishes with the
// database.
//
// Compiled only under the `MigrationAppContainerToCatalog` trait, which every
// migration floor from 1.0 through 1.7 enables. Retirement: raise the
// product's floor above 1.7, delete this target, its trait, its test target,
// the umbrella entry in `GLKMigrationCatalog`, and the one call in the app's
// GatewayRuntime. Nothing else in the product knows the old layout existed.

import Foundation
import MootProductIdentity
import GeniusLocusKit
import OSLog

/// Moves a pre-catalog Apple app estate into its catalog record's directory.
public enum AppContainerLayoutMigration {

    private static let logger = Logger(
        subsystem: MootProductIdentity.Logging.subsystem, category: "GLKMigrationAppContainerToCatalog")

    /// The folder the pre-catalog app created under Application Support, and
    /// the file names it used. Spelled here and nowhere else in the product.
    public static let legacyFolder = "mootx01"
    public static let legacyDatabase = "mootx01.sqlite"
    static let legacyDatabaseWAL = "mootx01.sqlite-wal"
    static let legacyDatabaseSHM = "mootx01.sqlite-shm"

    /// What one run did.
    public enum Outcome: Sendable, Equatable {
        /// No legacy database in the container, or the record is not the
        /// registered default estate. Nothing touched.
        case nothingToMove
        /// The named legacy files (basenames, in move order) now sit in the
        /// record's directory under the catalog's names.
        case moved(files: [String])
        /// Both the legacy database and the record's database exist. Nothing
        /// touched; the user decides which estate is the default.
        case refused(legacy: URL, catalog: URL)
    }

    /// Legacy name → catalog name, in move order: sidecars first, the main
    /// database last (see the file comment for why).
    static let moveOrder: [(legacy: String, catalog: String)] = [
        (legacyDatabaseWAL, EstateCatalogNames.databaseWAL),
        (legacyDatabaseSHM, EstateCatalogNames.databaseSHM),
        (legacyDatabase, EstateCatalogNames.database),
    ]

    /// `<applicationSupportDirectory>/mootx01/mootx01.sqlite`.
    public static func legacyDatabaseURL(applicationSupportDirectory: URL) -> URL {
        legacyDirectory(applicationSupportDirectory).appendingPathComponent(legacyDatabase, isDirectory: false)
    }

    /// True when a legacy database sits in the container and `record` is the
    /// registered default estate: the capsule has work, or a refusal, ahead.
    public static func pending(applicationSupportDirectory: URL, record: EstateRecord,
                               fileManager: FileManager = .default) -> Bool {
        guard record.kind == .registered, record.name == EstateCatalog.defaultName else { return false }
        return fileManager.fileExists(atPath: legacyDatabaseURL(applicationSupportDirectory: applicationSupportDirectory).path)
    }

    /// Run the move. Idempotent: a migrated container returns `.nothingToMove`;
    /// a run interrupted mid-move resumes on the next call.
    ///
    /// - Parameter relocateKey: moves the estate's key from the legacy database
    ///   path to the record's database path; `EstateOpenPosture.relocateKey`
    ///   in production, a recorder in tests.
    /// - Throws: the key relocation error, or the file-system error of the
    ///   rename that failed. Files moved before the failure stay moved; the
    ///   legacy database is still in place, so the next run resumes.
    public static func run(applicationSupportDirectory: URL, into record: EstateRecord,
                           fileManager: FileManager = .default,
                           relocateKey: (URL, URL) throws -> Bool = { try EstateOpenPosture.relocateKey(from: $0, to: $1) }
    ) throws -> Outcome {
        guard pending(applicationSupportDirectory: applicationSupportDirectory, record: record, fileManager: fileManager) else {
            return .nothingToMove
        }
        let legacy = legacyDirectory(applicationSupportDirectory)
        let legacyDatabaseURL = legacy.appendingPathComponent(legacyDatabase, isDirectory: false)
        if fileManager.fileExists(atPath: record.databaseURL.path) {
            logger.error("legacy app estate at \(legacyDatabaseURL.path, privacy: .public) and catalog estate at \(record.databaseURL.path, privacy: .public) both exist; refusing")
            return .refused(legacy: legacyDatabaseURL, catalog: record.databaseURL)
        }
        try fileManager.createDirectory(at: record.directory, withIntermediateDirectories: true)
        if try relocateKey(legacyDatabaseURL, record.databaseURL) {
            logger.info("estate key moved to the account of \(record.databaseURL.path, privacy: .public)")
        }
        var moved: [String] = []
        for step in moveOrder {
            let source = legacy.appendingPathComponent(step.legacy, isDirectory: false)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try fileManager.moveItem(at: source, to: record.directory.appendingPathComponent(step.catalog, isDirectory: false))
            moved.append(step.legacy)
        }
        // The old folder held only the estate; once empty it goes too. A folder
        // that still holds anything (a file this capsule does not know) stays.
        if let remaining = try? fileManager.contentsOfDirectory(atPath: legacy.path), remaining.isEmpty {
            try? fileManager.removeItem(at: legacy)
        }
        logger.info("legacy app estate moved into \(record.directory.path, privacy: .public): \(moved.joined(separator: ", "), privacy: .public)")
        return .moved(files: moved)
    }

    private static func legacyDirectory(_ applicationSupportDirectory: URL) -> URL {
        applicationSupportDirectory.appendingPathComponent(legacyFolder, isDirectory: true)
    }
}
