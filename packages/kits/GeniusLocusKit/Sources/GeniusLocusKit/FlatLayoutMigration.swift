// Flat-layout → catalog-layout adoption.
//
// Root cause of this code's existence: every 1.0.x Swift install kept its
// one estate FLAT in the configuration directory
// (`~/Library/Application Support/<product>/estate.sqlite` and siblings).
// The estate catalog places the same estate at
// `<configuration>/databases/default/` and records it in
// `estatecatalog.json`. A machine upgraded across that line holds a
// populated flat estate that no catalog record names.
//
// Adoption runs INSIDE `EstateCatalog.open()`, the one call every opener of
// the default estate makes before it touches the database: the resident
// daemon, every `mootx01` command, `aria-mcp`, the app gateway and the
// maintainer tools all reach the catalog through it. That placement is the
// whole point. An earlier design ran the move only from `mootx01 install`
// and `mootx01 upgrade`; any process that opened the default estate before
// one of those ran (a daemon restarted by the package's postinstall, a login
// daemon, a bare `mootx01 serve`, the dashboard, a reboot after a
// half-finished install) created an empty catalog estate beside the
// populated flat one, and the capsule then found two default estates and
// refused. With the move in the open, no caller can create the catalog
// estate while an unadopted flat estate is present.
//
// What `run` does:
//   1. Looks for the flat database at `<configuration>/estate.sqlite`. Absent
//      means nothing to do — a fresh install, or a machine already migrated.
//   2. Refuses when the flat database AND the record's database both exist.
//      Two estates claiming the default slot is never guessed at; nothing is
//      touched. `reclaimDefaultSlot` resolves the one case that is provable
//      (below).
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
// Two openers at once: both see the flat database, both start the move, and
// the renames race. A rename whose source the other process already carried
// across fails with "no such file"; that failure is treated as "already
// moved" and the loop continues, so both processes finish with the same
// layout and neither reports an error for work the other did.
//
// The both-present case and `reclaimDefaultSlot`. Machines upgraded with a
// package that restarted the daemon before adopting (the ordering defect
// this placement removes) hold a populated flat estate AND a catalog estate
// the daemon created minutes later. That catalog estate is not empty: a
// registered serve seeds one charter hint drawer per default wing, and the
// encode pass may derive facts and tunnels from those hints. It holds no
// user content, and that is provable without guessing: the charter drawers
// carry FIXED ids (`charterDrawerID(forWingIndex:)`), so an estate whose
// every drawer is a charter, whose every fact and tunnel derives from a
// charter, whose diary is empty and whose only rooms are the hint rooms of
// default wings holds exactly what the product seeded and nothing the user
// wrote. `reclaimDefaultSlot` opens the catalog estate read-only, checks
// that, and on proof retires the catalog estate's files AND its Keychain
// key (the key account is a hash of the database path; without disposing it
// `relocateKey` finds a key already at the destination and moves nothing,
// and the adopted estate comes up unreadable), then runs the move. Any
// drawer, fact, tunnel, diary entry or room outside that set, or any failure
// to open the catalog estate, is a refusal; the operator decides. The
// reclaim is async because it reads the estate through LocusKit's verbs, so
// it lives with the commands that own the daemon (`mootx01 install` and
// `mootx01 upgrade`), not in the synchronous open.
//
// What did NOT move, and why there is no base-directory capsule on this port:
// the Apple base directory is `~/Library/Application Support/com.mootx01.ce`
// on a 1.0.x install and on this one alike; the folder name is
// `MootProductIdentity.Storage.applicationSupportFolder` and it has held that
// value since before the catalog. Only the layout inside the base moved,
// which is this code. The Rust port has the opposite case: its layout was
// always `databases/<name>/` but its Windows base moved from
// `%LOCALAPPDATA%\MOOTx01` to `%LOCALAPPDATA%\com.mootx01.ce`, so that port
// carries a base-directory capsule
// (`rust-migrations/src/windows_base_directory_adoption.rs`) and no layout
// adoption. The two ports differ for that reason and no other.
//
// The commands own the daemon. A flat estate has no PID marker (the marker
// arrived with the catalog), so the marker-based quiesce the other upgrade
// steps use cannot see the resident that serves it; `install` and `upgrade`
// ask `pending(configurationDirectory:)` BEFORE their catalog open and stop
// the launchd daemon unconditionally when it is true, because a flat estate
// at the configuration directory is by definition the resident's estate. The
// resident itself adopts on its own open when it is the first opener.
//
// Compiled under the `MigrationFlatLayoutToCatalog` trait, which the package
// enables by default and which every migration floor from 1.0 through 1.7
// also enables: every flat estate that ever shipped is at or below format
// 1.7. The define reaches this target and its tests; no separate capsule
// target exists because the open itself has to call the move.
//
// Retirement: raise the product's floor above 1.7, then delete
//   - this file and the `GLK_MIGRATION_FLAT_LAYOUT_TO_CATALOG` block in
//     `EstateCatalog.open()`, the `twoDefaultEstates` catalog error, the
//     trait, its default-trait entry and the two defines
//     (`packages/kits/GeniusLocusKit/Package.swift`),
//   - `FlatLayoutMigrationTests.swift` beside the other GeniusLocusKit tests,
//   - `apps/mootx01/Sources/mootx01/Commands/FlatLayoutStep.swift`, the whole
//     file, and its call sites in `UpgradeCommand.run` and
//     `InstallCommand.handleExistingDatabase`, with the define in both
//     `apps/mootx01/Package*.swift` manifests.
// Nothing else in the product knows the flat layout existed.

#if GLK_MIGRATION_FLAT_LAYOUT_TO_CATALOG

import Foundation
import LocusKit
import MootProductIdentity
import OSLog
import PersistenceKit
import PersistenceKitSQLite

/// Moves a pre-catalog flat estate into its catalog record's directory.
public enum FlatLayoutMigration {

    private static let logger = Logger(
        subsystem: MootProductIdentity.Logging.subsystem, category: "GeniusLocusKit")

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

    /// The flat files this code moves, in move order. Siblings first, the
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

    /// True when a flat database sits at `configurationDirectory`: an
    /// adoption, or a refusal, is ahead of the next catalog open. The
    /// commands that own the daemon ask this BEFORE they open the catalog,
    /// so the resident is stopped only when a move is actually due and
    /// before the open performs it.
    public static func pending(configurationDirectory: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: flatURL(EstateCatalogNames.database, in: configurationDirectory).path)
    }

    /// True when a flat database sits at `configurationDirectory` and `record`
    /// is the registered default estate, the only record a flat estate can
    /// become.
    public static func pending(configurationDirectory: URL, record: EstateRecord,
                               fileManager: FileManager = .default) -> Bool {
        guard record.kind == .registered, record.name == EstateCatalog.defaultName else { return false }
        return pending(configurationDirectory: configurationDirectory, fileManager: fileManager)
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
            do {
                try fileManager.moveItem(at: source, to: record.directory.appendingPathComponent(name, isDirectory: false))
            } catch CocoaError.fileNoSuchFile {
                // Another opener carried this file across between the
                // existence check and the rename (see the file comment).
                continue
            }
            moved.append(name)
        }
        logger.info("flat estate moved into \(record.directory.path, privacy: .public): \(moved.joined(separator: ", "), privacy: .public)")
        return .moved(files: moved)
    }

    // MARK: - The both-present case

    /// Why a catalog estate could not be retired in favour of the flat one.
    /// Every case is a refusal: the operator decides.
    public enum ReclaimRefusal: Sendable, Equatable, CustomStringConvertible {
        /// The catalog estate holds something the product did not seed.
        case userContent(String)
        /// The catalog estate could not be opened for the check.
        case unreadable(String)

        public var description: String {
            switch self {
            case .userContent(let what): return "the catalog estate holds \(what)"
            case .unreadable(let detail): return "the catalog estate could not be read: \(detail)"
            }
        }
    }

    /// What `reclaimDefaultSlot` did.
    public enum ReclaimOutcome: Sendable, Equatable {
        /// `run` had nothing to do, or only one layout held a database and
        /// the plain move ran; carries that move's outcome.
        case moved(Outcome)
        /// The catalog estate held only the product's seeded charters; its
        /// files and Keychain key were retired and the flat estate moved in.
        case reclaimed(retired: [String], moved: [String])
        /// Both layouts hold a database and the catalog estate is not
        /// provably free of user content. Nothing touched.
        case refused(flat: URL, catalog: URL, reason: ReclaimRefusal)
    }

    /// Resolve a default slot claimed by both layouts when that is provable,
    /// then run the move; otherwise behave exactly as `run`.
    ///
    /// The proof is the one described in the file comment: every drawer of
    /// the catalog estate is a default wing's charter hint (fixed id), every
    /// fact and tunnel derives from one, the diary is empty and the only
    /// rooms are hint rooms of default wings. On proof the catalog record's
    /// owned files and the legacy plaintext marker are removed, the Keychain
    /// key for the catalog database path is disposed, and `run` moves the
    /// flat estate in.
    ///
    /// - Parameter ownerIdentifier: the owner credential the product opens
    ///   estates with; the check opens the catalog estate through LocusKit.
    /// - Throws: a file-system error removing a retired file, or whatever
    ///   `run` throws. A failure to OPEN the catalog estate is a refusal, not
    ///   an error: the state is left for the operator.
    public static func reclaimDefaultSlot(configurationDirectory: URL, record: EstateRecord,
                                          ownerIdentifier: String,
                                          fileManager: FileManager = .default,
                                          relocateKey: (URL, URL) throws -> Bool = { try EstateOpenPosture.relocateKey(from: $0, to: $1) }
    ) async throws -> ReclaimOutcome {
        guard pending(configurationDirectory: configurationDirectory, record: record, fileManager: fileManager),
              fileManager.fileExists(atPath: record.databaseURL.path) else {
            return .moved(try run(configurationDirectory: configurationDirectory, into: record,
                                  fileManager: fileManager, relocateKey: relocateKey))
        }
        let flatDatabase = flatURL(EstateCatalogNames.database, in: configurationDirectory)
        if let refusal = await userContent(in: record, ownerIdentifier: ownerIdentifier) {
            logger.error("catalog estate at \(record.databaseURL.path, privacy: .public) not retired: \(refusal.description, privacy: .public)")
            return .refused(flat: flatDatabase, catalog: record.databaseURL, reason: refusal)
        }
        var retired: [String] = []
        for url in record.ownedFileURLs + [record.legacyEncryptionOptOutURL]
        where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
            retired.append(url.lastPathComponent)
        }
        for failure in EstateOpenPosture.disposeKey(databaseURL: record.databaseURL) {
            logger.error("catalog estate retired but its key could not be removed: \(String(describing: failure), privacy: .public)")
        }
        logger.info("catalog estate at \(record.directory.path, privacy: .public) held only seeded charters; retired \(retired.joined(separator: ", "), privacy: .public)")
        switch try run(configurationDirectory: configurationDirectory, into: record,
                       fileManager: fileManager, relocateKey: relocateKey) {
        case .moved(let files):
            return .reclaimed(retired: retired, moved: files)
        case .nothingToMove, .refused:
            // Unreachable by construction: the flat database was present and
            // the record's database was just removed. Reported as the plain
            // outcome rather than hidden.
            return .moved(.nothingToMove)
        }
    }

    /// Nil when the catalog estate provably holds only what the product
    /// seeded; otherwise the first thing found that the user could lose, or
    /// why the estate could not be read.
    static func userContent(in record: EstateRecord, ownerIdentifier: String) async -> ReclaimRefusal? {
        let storage: SQLiteStorage
        let estate: LocusKit.Estate
        do {
            let resolved = try EstateOpenPosture.resolve(for: record)
            storage = try SQLiteStorage(configuration: EstateConfiguration(
                estateID: UUID(),
                backend: .sqlite(url: record.databaseURL, busyTimeout: 5),
                encryptionConfig: resolved.encryption))
            estate = try await LocusKit.Estate.open(
                storage: storage, owner: OwnerCredentials(ownerIdentifier: ownerIdentifier))
        } catch {
            return .unreadable(String(describing: error))
        }
        let verdict: ReclaimRefusal?
        do {
            verdict = try await seededOnlyVerdict(estate)
        } catch {
            verdict = .unreadable(String(describing: error))
        }
        do {
            try await estate.close()
        } catch {
            logger.error("closing the catalog estate after the check: \(String(describing: error), privacy: .public)")
        }
        await storage.close()
        return verdict
    }

    /// The proof itself, over LocusKit's verbs. Order: rooms, drawers,
    /// facts, tunnels, diary; the first foreign item names the refusal.
    private static func seededOnlyVerdict(_ estate: LocusKit.Estate) async throws -> ReclaimRefusal? {
        let wingNames = Set(LocusKit.defaultWings.map(\.name))
        let charterIDs = Set(LocusKit.defaultWings.indices.map { LocusKit.charterDrawerID(forWingIndex: $0) })
        for room in try await estate.listRooms(in: nil)
        where !wingNames.contains(room.wing) || room.name != LocusKit.hintRoom {
            return .userContent("a room '\(room.wing)/\(room.name)' outside the seeded charter rooms")
        }
        for drawer in try await estate.allDrawers() where !charterIDs.contains(drawer.id) {
            return .userContent("a drawer (\(drawer.id)) that is not a charter hint")
        }
        for fact in try await estate.allKGFacts() where !charterIDs.contains(fact.sourceDrawerID) {
            return .userContent("a fact (\(fact.id)) not derived from a charter hint")
        }
        for tunnel in try await estate.allTunnels()
        where tunnel.sourceDrawerId.map({ !charterIDs.contains($0) }) ?? true {
            return .userContent("a tunnel (\(tunnel.id)) not derived from a charter hint")
        }
        if let entry = try await estate.allDiaryEntries().first {
            return .userContent("a diary entry (\(entry.id))")
        }
        return nil
    }

    private static func flatURL(_ name: String, in configurationDirectory: URL) -> URL {
        configurationDirectory.appendingPathComponent(name, isDirectory: false)
    }
}

#endif
