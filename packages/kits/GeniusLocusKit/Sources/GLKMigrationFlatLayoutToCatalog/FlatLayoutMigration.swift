// Flat-layout → catalog-layout migration capsule.
//
// Root cause of this capsule's existence: every 1.0.x Swift install kept its
// one estate FLAT in the configuration directory
// (`~/Library/Application Support/<product>/estate.sqlite` and siblings).
// The estate catalog places the same estate at
// `<configuration>/databases/default/` and records it in
// `estatecatalog.json`. A machine upgraded across that line holds a
// populated flat estate that no catalog record names; without this capsule
// the first catalog open would create an empty default record beside it and
// every later step, and the next `serve`, would treat the machine as a first
// run. `mootx01 upgrade` is the only migration vehicle, so this is where the
// move lives.
//
// What the capsule does:
//   1. Looks for the flat database at `<configuration>/estate.sqlite`. Absent
//      means nothing to do — a fresh install, or a machine already migrated.
//   2. Refuses when the flat database AND the record's database both exist.
//      Two estates claiming the default slot is an operator decision, never a
//      guess; nothing is touched.
//   3. Otherwise moves the estate's Keychain key to the account of the new
//      database path (`EstateOpenPosture.relocateKey`): the key is looked up
//      by a hash of the file's path, so an encrypted estate moved without its
//      key would fail closed on its next open. A plaintext estate has no key
//      and nothing moves. The key goes first so an interrupted run resumes
//      with the key already in place.
//   4. Then renames each flat file the estate owns into the record's
//      directory: the queue database and its WAL/SHM, the vectors sidecar,
//      the drain lease, the manifest and PID marker if a pre-catalog build
//      left them, the legacy `no-encrypt` marker, the main database's WAL and
//      SHM, and the main database LAST. Same volume, so each rename is atomic
//      and no bytes are copied.
//
// Why the main database moves last: a crash mid-move leaves the flat
// database in place with some siblings already across. The next run sees the
// flat database present and the record's database absent, so it resumes,
// skipping every sibling no longer at the source, and finishes with the
// database. Had the database moved first, a crash would leave its WAL behind
// at the old path and the next run would see nothing to do.
//
// The caller owns the daemon. A flat estate has no PID marker (the marker
// arrived with the catalog), so the marker-based quiesce the other upgrade
// steps use cannot see the resident that serves it; the command stops the
// launchd daemon unconditionally around this capsule because a flat estate at
// the configuration directory is by definition the resident's estate.
//
// Compiled only under the `MigrationFlatLayoutToCatalog` trait, which every
// migration floor from 1.0 through 1.7 enables: every flat estate that ever
// shipped is at or below format 1.7. Retirement: raise the product's floor
// above 1.7, delete this target, its trait, its test target, the umbrella
// entry in `GLKMigrationCatalog`, and the one block in `UpgradeCommand`.
// Nothing else in the product knows the flat layout existed.

import Foundation
import MootProductIdentity
import GeniusLocusKit
import OSLog

/// Moves a pre-catalog flat estate into its catalog record's directory.
public enum FlatLayoutMigration {

    private static let logger = Logger(
        subsystem: MootProductIdentity.Logging.subsystem, category: "GLKMigrationFlatLayoutToCatalog")

    /// What one run did.
    public enum Outcome: Sendable, Equatable {
        /// No flat database at the configuration directory, or the record is
        /// not the registered default estate. Nothing touched.
        case nothingToMove
        /// The named files (basenames, in move order) now sit in the record's
        /// directory and no longer at the configuration directory.
        case moved(files: [String])
        /// Both the flat database and the record's database exist. Nothing
        /// touched; the operator decides which estate is the default.
        case refused(flat: URL, catalog: URL)
    }

    /// The flat files this capsule moves, in move order. Siblings first, the
    /// main database last (see the file comment for why).
    static let moveOrder: [String] = [
        EstateCatalogNames.queue, EstateCatalogNames.queueWAL, EstateCatalogNames.queueSHM,
        EstateCatalogNames.vectors,
        EstateCatalogNames.drainLease,
        EstateCatalogNames.manifest, EstateCatalogNames.pid,
        EstateCatalogNames.legacyEncryptionOptOut,
        EstateCatalogNames.databaseWAL, EstateCatalogNames.databaseSHM,
        EstateCatalogNames.database,
    ]

    /// True when a flat database sits at `configurationDirectory` and `record`
    /// is the registered default estate: the capsule has work, or a refusal,
    /// ahead. The command asks this first so the daemon is stopped only when
    /// a move is actually due.
    public static func pending(configurationDirectory: URL, record: EstateRecord,
                               fileManager: FileManager = .default) -> Bool {
        guard record.kind == .registered, record.name == EstateCatalog.defaultName else { return false }
        return fileManager.fileExists(atPath: flatURL(EstateCatalogNames.database, in: configurationDirectory).path)
    }

    /// Run the move. Idempotent: a migrated machine returns `.nothingToMove`;
    /// a run interrupted mid-move resumes on the next call.
    ///
    /// - Parameter relocateKey: moves the estate's key from the flat database
    ///   path to the record's database path; `EstateOpenPosture.relocateKey`
    ///   in production, a recorder in tests.
    /// - Throws: the key relocation error, or the file-system error of the
    ///   rename that failed. Files moved before the failure stay moved; the
    ///   flat database is still in place, so the next run resumes.
    public static func run(configurationDirectory: URL, into record: EstateRecord,
                           fileManager: FileManager = .default,
                           relocateKey: (URL, URL) throws -> Bool = { try EstateOpenPosture.relocateKey(from: $0, to: $1) }
    ) throws -> Outcome {
        guard pending(configurationDirectory: configurationDirectory, record: record, fileManager: fileManager) else {
            return .nothingToMove
        }
        let flatDatabase = flatURL(EstateCatalogNames.database, in: configurationDirectory)
        if fileManager.fileExists(atPath: record.databaseURL.path) {
            logger.error("flat estate at \(flatDatabase.path, privacy: .public) and catalog estate at \(record.databaseURL.path, privacy: .public) both exist; refusing")
            return .refused(flat: flatDatabase, catalog: record.databaseURL)
        }
        try fileManager.createDirectory(at: record.directory, withIntermediateDirectories: true)
        if try relocateKey(flatDatabase, record.databaseURL) {
            logger.info("estate key moved to the account of \(record.databaseURL.path, privacy: .public)")
        }
        var moved: [String] = []
        for name in moveOrder {
            let source = flatURL(name, in: configurationDirectory)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try fileManager.moveItem(at: source, to: record.directory.appendingPathComponent(name, isDirectory: false))
            moved.append(name)
        }
        logger.info("flat estate moved into \(record.directory.path, privacy: .public): \(moved.joined(separator: ", "), privacy: .public)")
        return .moved(files: moved)
    }

    private static func flatURL(_ name: String, in configurationDirectory: URL) -> URL {
        configurationDirectory.appendingPathComponent(name, isDirectory: false)
    }
}
