// EstateCatalog.swift
//
// The registry of estates: which estates exist, what they are called, and
// where each one lives. Storage and retrieval of records, nothing else. The
// catalog never creates, opens, moves or deletes an estate's files; it only
// remembers where they are.
//
// An estate is a self-contained directory. Two directories matter:
//
// - The configuration directory. Computed from the platform, never passed
//   in, never stored, never moved. `~/Library/Application Support/` never
//   changes; the product folder under it (`com.mootx01.ce` today) is spelled
//   once in MootProductIdentity and nowhere else. It holds
//   `estatecatalog.json` and the other configuration files
//   for the life of the install. The catalog is always found there.
// - The default database location. Recorded inside `estatecatalog.json` as
//   an absolute path. On first run it is `<configuration>/databases`, so an
//   estate lives at `~/Library/Application Support/<identifier>/databases/
//   <estatename>/[estate files]`. Bare estate names resolve under it.
//   Changing it is `moveDefault`: every `<estatename>/[estate files]` moves
//   to the new base path and the old `databases` directory is removed, so
//   the configuration directory holds only configuration files. In this
//   version it refuses.
//
// Any other estate answers the question of where it is stored when it is
// registered, and may live on any volume.
//
// Two files, two scopes:
//
// - `estatecatalog.json` in the configuration directory: the registry, name
//   to directory, plus the default location. One per install.
// - `estate.json` inside every estate directory, registered or transient: the
//   estate's own manifest (`EstateManifest`): its name, the schema
//   and estate-format versions it was written at, its encryption posture,
//   when it was created. Everything about the estate lives with the estate,
//   so moving the directory moves all of it. Process markers (`estate.pid`)
//   live there too: "this estate is being served" is a fact about the estate.
//
// Every caller that needs an estate asks the catalog and takes the first
// record: the active estate is always at index zero. Nothing outside this
// file joins a filename onto an estate directory; `EstateRecord`'s computed
// properties are the only spelling of the estate's on-disk shape, so the two
// ports cannot drift on layout again.
//
// Two kinds of record share the array. Registered records live in
// `estatecatalog.json`. Transient records come from a command line (`--db <value>`)
// for one invocation, are never written, and are forgotten at exit.
//
// A record also says which backend holds the estate's database. SQLite, the
// default, keeps `estate.sqlite` and its sidecars inside the directory.
// PostgreSQL keeps the database at a connection string recorded on the
// record; the directory then holds only the manifest and the process marker.
// The backend is a fact about where the estate is, so it lives in the
// catalog beside the directory, never in the environment.
//
// `--db <value>` and `register <value>` share one rule (`EstateSelector`):
// `<value>` splits into a path and a name, the name being the last component.
// A bare `~` or a leading `~/` is the process home; `~user` is a literal
// component in both ports (the Rust port follows Linux conventions and has
// no user-database lookup). A registered name selects its record. An
// unregistered name with a path is a transient attach at `path/name/`. An
// unregistered name without a path is a format error: registering is a
// separate command, `--db` never registers. `registeredRecord(selecting:)`
// answers the other question a caller has about a `<value>`: whether it
// names a registered estate, by name or by the canonical path of its
// directory, so a guard that must protect registered estates can tell one
// named by its directory from a genuine transient.
//
// Rust twin: `rust/src/estate_catalog.rs`. Both ports read and write the same
// `estatecatalog.json` and must produce the same records for the same file.

import Foundation
import MootProductIdentity
import OSLog

// MARK: - Names

/// Every name the catalog and the estate layout use, in one place. The Rust
/// twin carries the same table; change a name here and there together.
public enum EstateCatalogNames {
    /// The catalog file inside the configuration directory. Spelled in
    /// MootProductIdentity so the daemon provider's census, which cannot
    /// depend on this kit, names the same files.
    public static let catalogFile = MootProductIdentity.Storage.catalogFile
    /// The folder under the configuration directory that is the default
    /// database location on first run.
    public static let databasesFolder = MootProductIdentity.Storage.databasesFolder
    /// The primary estate's name.
    public static let defaultEstate = MootProductIdentity.Storage.defaultEstateName

    /// The files one estate owns, inside its directory.
    public static let manifest = "estate.json"
    public static let pid = "estate.pid"
    public static let database = MootProductIdentity.Storage.estateDatabaseFile
    public static let databaseWAL = "estate.sqlite-wal"
    public static let databaseSHM = "estate.sqlite-shm"
    public static let queue = "estate.queue.sqlite"
    public static let queueWAL = "estate.queue.sqlite-wal"
    public static let queueSHM = "estate.queue.sqlite-shm"
    public static let vectors = "estate.vectors.vec"
    public static let drainLease = "encode.drain.lease"
    /// The pre-manifest plaintext marker. Not an owned file: `mootx01 upgrade`
    /// folds it into the manifest's `encryption` and deletes it.
    public static let legacyEncryptionOptOut = "no-encrypt"
}

// MARK: - EstateRecord

/// Whether a record is stored in `estatecatalog.json` or exists for one invocation.
public enum EstateRecordKind: String, Sendable, Codable, Equatable {
    case registered
    case transient
}

/// Which persistence backend holds the estate's database.
public enum EstateBackend: Sendable, Equatable {
    /// `estate.sqlite` and its sidecars inside the record's directory. The
    /// default; a catalog entry without a `backend` field means this.
    case sqlite
    /// A PostgreSQL database reached through `connectionString`. The record's
    /// directory holds the manifest and the process marker; the database
    /// files derived from the directory never exist for this backend.
    case postgresql(connectionString: String)

    /// The word `estatecatalog.json` records for each case.
    public var kindName: String {
        switch self {
        case .sqlite: return "sqlite"
        case .postgresql: return "postgresql"
        }
    }
}

extension EstateBackend: Codable {
    private enum CodingKeys: String, CodingKey { case kind, connectionString }

    /// `{"kind": "sqlite"}` or `{"kind": "postgresql", "connectionString": "..."}`.
    /// Spelled out rather than synthesized so the Rust twin reads the same
    /// shape without Swift's enum-as-object encoding.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        let connectionString = try container.decodeIfPresent(String.self, forKey: .connectionString)
        switch (kind, connectionString) {
        case ("sqlite", nil):
            self = .sqlite
        case ("postgresql", let string?) where !string.isEmpty:
            self = .postgresql(connectionString: string)
        case ("sqlite", _?):
            throw DecodingError.dataCorruptedError(
                forKey: .connectionString, in: container,
                debugDescription: "a sqlite backend carries no connectionString")
        case ("postgresql", _):
            throw DecodingError.dataCorruptedError(
                forKey: .connectionString, in: container,
                debugDescription: "a postgresql backend needs a non-empty connectionString")
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "unknown backend kind '\(kind)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kindName, forKey: .kind)
        if case .postgresql(let connectionString) = self {
            try container.encode(connectionString, forKey: .connectionString)
        }
    }
}

/// One estate: its name and the directory that holds it.
public struct EstateRecord: Sendable, Codable, Equatable {
    /// The name, one path component.
    public let name: String

    /// The directory holding every file of the estate.
    public let directory: URL

    /// Registered (in the file) or transient (this invocation only).
    public let kind: EstateRecordKind

    /// Where the database lives: in the directory (SQLite) or at a PostgreSQL
    /// connection string. Transient records are always SQLite: `--db` names a
    /// directory and nothing else.
    public let backend: EstateBackend

    public init(name: String, directory: URL, kind: EstateRecordKind = .registered,
                backend: EstateBackend = .sqlite) {
        self.name = name
        self.directory = directory.standardizedFileURL
        self.kind = kind
        self.backend = backend
    }

    /// The estate's own manifest, `estate.json` (`EstateManifest`).
    public var manifestURL: URL { directory.appendingPathComponent(EstateCatalogNames.manifest) }

    /// The process marker written by whichever process is serving the estate.
    public var pidURL: URL { directory.appendingPathComponent(EstateCatalogNames.pid) }

    /// The estate database.
    public var databaseURL: URL { directory.appendingPathComponent(EstateCatalogNames.database) }

    /// SQLite write-ahead log and shared-memory sidecars of the database.
    public var databaseWALURL: URL { directory.appendingPathComponent(EstateCatalogNames.databaseWAL) }
    public var databaseSHMURL: URL { directory.appendingPathComponent(EstateCatalogNames.databaseSHM) }

    /// The dreaming and encode queue database and its SQLite sidecars.
    public var queueURL: URL { directory.appendingPathComponent(EstateCatalogNames.queue) }
    public var queueWALURL: URL { directory.appendingPathComponent(EstateCatalogNames.queueWAL) }
    public var queueSHMURL: URL { directory.appendingPathComponent(EstateCatalogNames.queueSHM) }

    /// The resident vector arrays (binary fingerprints and float vectors).
    public var vectorsURL: URL { directory.appendingPathComponent(EstateCatalogNames.vectors) }

    /// The encode-drain lease that serialises drainers on this estate.
    public var drainLeaseURL: URL { directory.appendingPathComponent(EstateCatalogNames.drainLease) }

    /// The pre-manifest plaintext marker, if an older estate still carries it.
    /// Read only by `mootx01 upgrade`, which folds it into the manifest.
    public var legacyEncryptionOptOutURL: URL { directory.appendingPathComponent(EstateCatalogNames.legacyEncryptionOptOut) }

    /// The `--db <value>` that selects this estate again in another process:
    /// the name for a registered estate, the directory path for a transient
    /// one. Detached children (drain, dream) are launched with this.
    public var selectorArgument: String {
        kind == .registered ? name : directory.path
    }

    /// Every file the estate owns, in a fixed order. Deletion, copy and
    /// inventory walk this list and nothing else. For a PostgreSQL record
    /// only the manifest and the process marker can exist; the rest are
    /// derived names that no process creates, and walkers skip absent files.
    public var ownedFileURLs: [URL] {
        [manifestURL, pidURL,
         databaseURL, databaseWALURL, databaseSHMURL,
         queueURL, queueWALURL, queueSHMURL,
         vectorsURL, drainLeaseURL]
    }
}

// MARK: - EstateManifest

/// The estate's own manifest, stored as `estate.json` in its directory.
/// Written when the estate is created and whenever a recorded fact changes;
/// read by anything that needs to know about the estate without opening it.
public struct EstateManifest: Sendable, Codable, Equatable {
    /// The `estate.json` file format version.
    public static let currentFileVersion = 1

    /// At-rest encryption posture.
    public enum Encryption: String, Sendable, Codable, Equatable {
        case encrypted
        case plaintext
    }

    /// The only keys `estate.json` may carry. A manifest with any other key
    /// is refused: a path, a redirect or any field this version does not know
    /// could hide a rogue database under a manifest that looks right.
    public static let allowedKeys: Set<String> =
        ["fileVersion", "name", "schemaVersion", "formatVersion", "encryption", "created"]

    public let fileVersion: Int
    /// The estate's name; the same word as its directory.
    public let name: String
    /// The composite schema version the estate was last written at
    /// (`GeniusLocusKitSchema.version`).
    public let schemaVersion: Int
    /// The estate format the estate was last written at (`EstateFormatVersion`).
    public let formatVersion: EstateFormatVersion
    public let encryption: Encryption
    /// ISO8601, UTC. Passed in; the catalog never reads the clock.
    public let created: String

    public init(name: String, schemaVersion: Int, formatVersion: EstateFormatVersion,
                encryption: Encryption, created: String) {
        self.fileVersion = Self.currentFileVersion
        self.name = name
        self.schemaVersion = schemaVersion
        self.formatVersion = formatVersion
        self.encryption = encryption
        self.created = created
    }
}

// MARK: - EstateCatalogError

/// Failures of the catalog. Every case names the file or estate involved.
public enum EstateCatalogError: Error, Sendable, Equatable, CustomStringConvertible {
    /// `estatecatalog.json` could not be read or was not valid JSON of the expected shape.
    case unreadableCatalog(url: URL, detail: String)
    /// `estatecatalog.json` could not be written.
    case unwritableCatalog(url: URL, detail: String)
    /// The catalog lists no estates.
    case emptyCatalog(url: URL)
    /// A name that is not a valid estate name (empty, `.`, `..`, or containing a path separator).
    case invalidName(String)
    /// A record with this name is already registered.
    case duplicateName(String)
    /// No record with this name is registered.
    case unknownName(String)
    /// The active estate (index zero) cannot be removed; make another active first.
    case cannotRemoveActive(String)
    /// `--db <value>` named an estate that is not registered and gave no path.
    case unregisteredWithoutPath(String)
    /// The operation exists in the interface but does nothing in this version.
    case notAvailableInThisVersion(operation: String)
    /// `estate.json` is missing, unreadable, or names a different estate.
    case unreadableEstateManifest(url: URL, detail: String)
    /// A pre-catalog flat estate and the default record's database both
    /// exist; the open touched nothing. `mootx01 upgrade` retires a catalog
    /// estate that holds only the product's seeded charters and adopts the
    /// flat one; anything else is the operator's decision.
    case twoDefaultEstates(flat: URL, catalog: URL)

    public var description: String {
        switch self {
        case .unreadableCatalog(let url, let detail):
            return "estate catalog at \(url.path) is unreadable: \(detail)"
        case .unwritableCatalog(let url, let detail):
            return "estate catalog at \(url.path) could not be written: \(detail)"
        case .emptyCatalog(let url):
            return "estate catalog at \(url.path) lists no estates"
        case .invalidName(let name):
            return "'\(name)' is not a valid estate name"
        case .duplicateName(let name):
            return "an estate named '\(name)' is already registered"
        case .unknownName(let name):
            return "no estate named '\(name)' is registered"
        case .cannotRemoveActive(let name):
            return "'\(name)' is the active estate and cannot be removed; activate another estate first"
        case .unregisteredWithoutPath(let value):
            return "'\(value)' is not a registered estate; an unregistered estate needs a path (<dir>/\(value))"
        case .notAvailableInThisVersion(let operation):
            return "\(operation) is not available in this version"
        case .unreadableEstateManifest(let url, let detail):
            return "estate manifest at \(url.path) is unreadable: \(detail)"
        case .twoDefaultEstates(let flat, let catalog):
            return """
                two default estates found and nothing was changed.
                  flat:    \(flat.path)
                  catalog: \(catalog.path)
                Run `mootx01 upgrade`: a catalog estate holding only the product's charter hints is retired and the flat estate adopted. Otherwise move or remove one of them, then run the command again.
                """
        }
    }
}

// MARK: - EstateCatalog

/// Manages `estatecatalog.json`: create, read, update and delete the
/// registry records of estates. Pure storage; it never touches an estate.
public struct EstateCatalog: Sendable, Equatable {

    /// The catalog file name inside the configuration directory.
    public static let fileName = EstateCatalogNames.catalogFile

    /// The product's folder name under Application Support, from the one
    /// central spelling in MootProductIdentity.
    public static var productIdentifier: String { MootProductIdentity.Storage.applicationSupportFolder }

    /// The name of the primary estate, the one `install` registers first.
    public static let defaultName = EstateCatalogNames.defaultEstate

    /// The configuration directory: where `estatecatalog.json` lives.
    /// `<home>/Library/Application Support/<productIdentifier>`, fixed for the
    /// life of the install. The home is the process family's
    /// (`MootProductIdentity.Storage.processHome`): the user's home for the
    /// unsandboxed CLI family, the group container for the sandboxed app
    /// family, so each family shares one catalog and neither can see the
    /// other's (DECISION_INSTALL_TAKEOVER_2026-09-08). Tests redirect it
    /// through `configurationDirectoryOverride`; nothing else can.
    public static var configurationDirectory: URL {
        if let override = configurationDirectoryOverride { return override }
        return MootProductIdentity.Storage.configurationDirectory
    }

    /// Test seam only. Not public: production code cannot point the catalog
    /// anywhere but the platform directory. Import with
    /// `@_spi(Testing) import GeniusLocusKit` to access from test targets.
    @_spi(Testing)
    nonisolated(unsafe) public static var configurationDirectoryOverride: URL?

    /// The default database location, read from the file. Absolute. Bare
    /// estate names resolve under it. Changed only by `moveDefault`.
    public let defaultLocation: URL

    /// The registered estates. Index zero is the active estate.
    public private(set) var records: [EstateRecord]

    /// The active estate: index zero.
    public var active: EstateRecord { records[0] }

    /// The catalog file: `<configuration>/estatecatalog.json`.
    public static var catalogURL: URL {
        configurationDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    /// The default database location a fresh install records:
    /// `<configuration>/databases`.
    public static var initialDefaultLocation: URL {
        configurationDirectory.appendingPathComponent(EstateCatalogNames.databasesFolder, isDirectory: true).standardizedFileURL
    }

    /// Where an estate lands when named without a path: `<default location>/<name>`.
    public func directory(forBareName name: String) -> URL {
        defaultLocation.appendingPathComponent(name, isDirectory: true).standardizedFileURL
    }

    // MARK: Create and read

    /// First run: create the catalog file recording `<configuration>/databases`
    /// as the default database location and one record, the default estate at
    /// `<default location>/default`. Refuses to overwrite: an existing file is
    /// loaded instead, so calling this twice is harmless.
    public static func create() throws -> EstateCatalog {
        let url = catalogURL
        if FileManager.default.fileExists(atPath: url.path) {
            return try load()
        }
        let location = initialDefaultLocation
        let catalog = EstateCatalog(
            defaultLocation: location,
            records: [EstateRecord(name: defaultName,
                                   directory: location.appendingPathComponent(defaultName, isDirectory: true))])
        try catalog.save()
        logger.info("estate catalog created at \(url.path, privacy: .public)")
        return catalog
    }

    /// Read the catalog file. Throws when it is missing, unreadable, or empty.
    public static func load() throws -> EstateCatalog {
        let url = catalogURL
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw EstateCatalogError.unreadableCatalog(url: url, detail: String(describing: error))
        }
        let file: CatalogFile
        do {
            file = try JSONDecoder().decode(CatalogFile.self, from: data)
        } catch {
            throw EstateCatalogError.unreadableCatalog(url: url, detail: String(describing: error))
        }
        guard file.version == CatalogFile.currentVersion else {
            throw EstateCatalogError.unreadableCatalog(
                url: url, detail: "unsupported catalog version \(file.version)")
        }
        guard !file.estates.isEmpty else { throw EstateCatalogError.emptyCatalog(url: url) }
        guard file.defaultLocation.hasPrefix("/") else {
            throw EstateCatalogError.unreadableCatalog(
                url: url, detail: "defaultLocation must be an absolute path")
        }
        let records = file.estates.map {
            EstateRecord(name: $0.name, directory: URL(fileURLWithPath: $0.path, isDirectory: true),
                         backend: $0.backend ?? .sqlite)
        }
        return EstateCatalog(defaultLocation: URL(fileURLWithPath: file.defaultLocation, isDirectory: true),
                             records: records)
    }

    /// Load the catalog, creating it on first run.
    /// The one call every command uses to find its estate: `open(...).active`.
    ///
    /// Under the `MigrationFlatLayoutToCatalog` trait the open also adopts a
    /// pre-catalog flat estate into the default record's directory before
    /// returning, so no caller can open the default estate, and create an
    /// empty one at the catalog path, while an unadopted flat estate exists
    /// (see `FlatLayoutMigration`). When both layouts hold a database the
    /// open throws `EstateCatalogError.twoDefaultEstates` and touches nothing.
    public static func open() throws -> EstateCatalog {
        let catalog: EstateCatalog
        if FileManager.default.fileExists(atPath: catalogURL.path) {
            catalog = try load()
        } else {
            catalog = try create()
        }
        #if GLK_MIGRATION_FLAT_LAYOUT_TO_CATALOG
        if let record = catalog.records.first(where: { $0.kind == .registered && $0.name == defaultName }),
           case .refused(let flat, let catalogDatabase) = try FlatLayoutMigration.run(
               configurationDirectory: configurationDirectory, into: record) {
            throw EstateCatalogError.twoDefaultEstates(flat: flat, catalog: catalogDatabase)
        }
        #endif
        return catalog
    }

    /// Open the catalog and make `--db <value>` the active estate for this
    /// invocation. A registered name selects its record. An unregistered name
    /// with a path attaches a transient record at `path/name/`. An unregistered
    /// name without a path is refused. Nothing is written.
    public static func open(selecting value: String) throws -> EstateCatalog {
        var catalog = try open()
        let selector = try EstateSelector(value)
        if selector.path == nil, let index = catalog.records.firstIndex(where: { $0.name == selector.name }) {
            let record = catalog.records.remove(at: index)
            catalog.records.insert(record, at: 0)
            return catalog
        }
        guard let directory = selector.directory else {
            throw EstateCatalogError.unregisteredWithoutPath(value)
        }
        let transient = EstateRecord(name: selector.name, directory: directory, kind: .transient)
        // A manifest left by an earlier run must describe THIS estate, carry
        // no unknown keys, and sit over regular files inside the directory;
        // otherwise the attach is refused before anything opens.
        if FileManager.default.fileExists(atPath: transient.manifestURL.path) {
            _ = try readManifest(of: transient)
        } else {
            try verifyFilesStayInside(transient)
        }
        catalog.records.insert(transient, at: 0)
        return catalog
    }

    /// The record with this name, if registered.
    public func record(named name: String) -> EstateRecord? {
        records.first { $0.name == name }
    }

    /// The registered record whose directory is `directory`, compared by
    /// canonical path: symbolic links in both are resolved (for the part of
    /// each path that exists) and the results standardised, so a registered
    /// estate reached through a linked volume or an alias resolves to its
    /// record. Transient records are never matched. Nil when no registered
    /// record lives there.
    public func record(atDirectory directory: URL) -> EstateRecord? {
        let wanted = Self.canonicalPath(of: directory)
        return records.first { $0.kind == .registered && Self.canonicalPath(of: $0.directory) == wanted }
    }

    /// The registered record a `--db <value>` names, or nil when the value
    /// names none: a bare name is looked up by name; a pathname is looked up
    /// by the canonical path of `path/name/`. Throws only for a value that
    /// is not a valid selector. Does not select and does not attach: this is
    /// the question "is that a registered estate?", asked before a caller
    /// decides whether a transient attach at that path is appropriate.
    public func registeredRecord(selecting value: String) throws -> EstateRecord? {
        let selector = try EstateSelector(value)
        guard let directory = selector.directory else { return record(named: selector.name) }
        return record(atDirectory: directory)
    }

    /// The comparison form of a directory path: symbolic links resolved and
    /// the result standardised. `resolvingSymlinksInPath` resolves the
    /// existing prefix of a path that does not fully exist, which is what the
    /// Rust twin's `canonical` does, so both ports compare the same string.
    static func canonicalPath(of directory: URL) -> String {
        directory.resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: Update and delete

    /// Register a new estate at a directory of the caller's choosing and save.
    /// The new record is appended; the active estate is unchanged. A
    /// PostgreSQL estate names its connection string here; its directory
    /// still holds the manifest and the process marker.
    public mutating func register(name: String, directory: URL, backend: EstateBackend = .sqlite) throws {
        guard Self.isValidName(name) else { throw EstateCatalogError.invalidName(name) }
        guard record(named: name) == nil else { throw EstateCatalogError.duplicateName(name) }
        records.append(EstateRecord(name: name, directory: directory, kind: .registered, backend: backend))
        try save()
    }

    /// Register from the same `<value>` shape `--db` takes: a bare name lands
    /// at `<default location>/<name>/`, a pathname at `path/name/`.
    public mutating func register(_ value: String) throws {
        let selector = try EstateSelector(value)
        try register(name: selector.name,
                     directory: selector.directory ?? directory(forBareName: selector.name))
    }

    /// Change the default database location. When implemented it moves each
    /// `<estatename>/[estate files]` under the old location to
    /// `<newLocation>/<estatename>/`, rewrites the affected records and the
    /// recorded default location, and removes the old `databases` directory,
    /// leaving the configuration directory holding only configuration files.
    ///
    /// Not available in this version: refuses without touching anything. The
    /// command that exposes it must run over stdio only and must refuse when
    /// any mootx01 server is running (system not idle); those gates are the
    /// command's, this is the storage operation behind them.
    public mutating func moveDefault(to newLocation: URL) throws {
        _ = newLocation
        throw EstateCatalogError.notAvailableInThisVersion(operation: "moveDefault")
    }

    /// Change where a registered estate's directory is and save. Records
    /// only; the caller is responsible for the estate's files having moved.
    /// The backend is unchanged.
    public mutating func relocate(name: String, to directory: URL) throws {
        guard let index = records.firstIndex(where: { $0.name == name }) else {
            throw EstateCatalogError.unknownName(name)
        }
        records[index] = EstateRecord(name: name, directory: directory, backend: records[index].backend)
        try save()
    }

    /// Rename a registered estate and save. Its directory does not change.
    public mutating func rename(_ name: String, to newName: String) throws {
        guard Self.isValidName(newName) else { throw EstateCatalogError.invalidName(newName) }
        guard let index = records.firstIndex(where: { $0.name == name }) else {
            throw EstateCatalogError.unknownName(name)
        }
        guard newName == name || record(named: newName) == nil else {
            throw EstateCatalogError.duplicateName(newName)
        }
        records[index] = EstateRecord(name: newName, directory: records[index].directory,
                                      backend: records[index].backend)
        try save()
    }

    /// Make a registered estate the active one, moving it to index zero, and save.
    public mutating func activate(name: String) throws {
        guard let index = records.firstIndex(where: { $0.name == name }) else {
            throw EstateCatalogError.unknownName(name)
        }
        let record = records.remove(at: index)
        records.insert(record, at: 0)
        try save()
    }

    /// Remove a registered estate from the catalog and save. Never touches the
    /// estate's files. The active estate cannot be removed.
    public mutating func remove(name: String) throws {
        guard let index = records.firstIndex(where: { $0.name == name }) else {
            throw EstateCatalogError.unknownName(name)
        }
        guard index != 0 else { throw EstateCatalogError.cannotRemoveActive(name) }
        records.remove(at: index)
        try save()
    }

    // MARK: Per-estate manifest

    /// Read `estate.json` from the record's directory. Refuses a file whose
    /// name does not match the record: a directory renamed by hand is not
    /// silently adopted under a new name.
    public static func readManifest(of record: EstateRecord) throws -> EstateManifest {
        let url = record.manifestURL
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw EstateCatalogError.unreadableEstateManifest(url: url, detail: String(describing: error))
        }
        // Strict shape: every top-level key must be one this version knows.
        // JSONDecoder ignores unknown keys, so they are checked here first. A
        // path, a redirect or any unknown field could hide a rogue database
        // under a manifest that looks right.
        let keys: Set<String>
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw EstateCatalogError.unreadableEstateManifest(url: url, detail: "not a JSON object")
            }
            keys = Set(object.keys)
        } catch let error as EstateCatalogError {
            throw error
        } catch {
            throw EstateCatalogError.unreadableEstateManifest(url: url, detail: String(describing: error))
        }
        let unknown = keys.subtracting(EstateManifest.allowedKeys).sorted()
        guard unknown.isEmpty else {
            throw EstateCatalogError.unreadableEstateManifest(
                url: url, detail: "unknown keys \(unknown); a manifest may not carry paths or redirects")
        }
        let manifest: EstateManifest
        do {
            manifest = try JSONDecoder().decode(EstateManifest.self, from: data)
        } catch {
            throw EstateCatalogError.unreadableEstateManifest(url: url, detail: String(describing: error))
        }
        guard manifest.fileVersion == EstateManifest.currentFileVersion else {
            throw EstateCatalogError.unreadableEstateManifest(
                url: url, detail: "unsupported estate.json version \(manifest.fileVersion)")
        }
        guard manifest.name == record.name else {
            throw EstateCatalogError.unreadableEstateManifest(
                url: url, detail: "names estate '\(manifest.name)' but the directory is '\(record.name)'")
        }
        try verifyFilesStayInside(record)
        return manifest
    }

    /// Every estate file that exists must be a regular file inside the estate
    /// directory. A symbolic link among them would let a manifest that looks
    /// right front for a database somewhere else; it is refused.
    public static func verifyFilesStayInside(_ record: EstateRecord) throws {
        let directory = record.directory.resolvingSymlinksInPath().standardizedFileURL.path
        for url in record.ownedFileURLs {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { continue }
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw EstateCatalogError.unreadableEstateManifest(
                    url: record.manifestURL,
                    detail: "\(url.lastPathComponent) is a symbolic link; estate files must be regular files in \(record.directory.path)")
            }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved.hasPrefix(directory + "/") else {
                throw EstateCatalogError.unreadableEstateManifest(
                    url: record.manifestURL,
                    detail: "\(url.lastPathComponent) resolves outside the estate directory")
            }
        }
    }

    /// Write `estate.json` into the record's directory, atomically, creating
    /// the directory if needed. The one file the catalog writes inside an
    /// estate; it is the manifest, not estate content.
    public static func writeManifest(_ configuration: EstateManifest,
                                          to record: EstateRecord) throws {
        let url = record.manifestURL
        guard configuration.name == record.name else {
            throw EstateCatalogError.unreadableEstateManifest(
                url: url, detail: "configuration names '\(configuration.name)' but the record is '\(record.name)'")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(configuration)
            try FileManager.default.createDirectory(at: record.directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw EstateCatalogError.unwritableCatalog(url: url, detail: String(describing: error))
        }
    }

    /// An estate name is one path component: non-empty, not `.` or `..`,
    /// and free of path separators.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\\")
    }

    // MARK: - EstateSelector

    /// The split of a `--db <value>` or `register <value>` argument into the
    /// path before the last component and the name that is the last component.
    /// A bare `~` or a leading `~/` expands to the process home and nothing
    /// else does (`~user` stays literal, as in the Rust port); a relative
    /// pathname is relative to the working directory. A value with no
    /// separator has a nil path.
    public struct EstateSelector: Sendable, Equatable {
        public let name: String
        public let path: URL?

        public init(_ value: String) throws {
            let expanded = Self.expandingTilde(value)
            let trimmed = expanded.hasSuffix("/") && expanded.count > 1
                ? String(expanded.dropLast()) : expanded
            guard !trimmed.isEmpty else { throw EstateCatalogError.invalidName(value) }
            if let slash = trimmed.lastIndex(of: "/") {
                let name = String(trimmed[trimmed.index(after: slash)...])
                let dir = String(trimmed[..<slash])
                guard EstateCatalog.isValidName(name) else { throw EstateCatalogError.invalidName(value) }
                let base = dir.isEmpty ? "/" : dir
                self.name = name
                self.path = URL(fileURLWithPath: base, isDirectory: true).standardizedFileURL
            } else {
                guard EstateCatalog.isValidName(trimmed) else { throw EstateCatalogError.invalidName(value) }
                self.name = trimmed
                self.path = nil
            }
        }

        /// `path/name/` when a path was given, nil otherwise.
        public var directory: URL? {
            path?.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        }

        /// `~` and `~/...` become the process home; every other value is
        /// returned unchanged. Deliberately not `expandingTildeInPath`, which
        /// also expands `~user`: the Rust port has no user-database lookup, so
        /// `~user/...` would name different directories in the two ports.
        static func expandingTilde(_ value: String) -> String {
            let home = NSHomeDirectory()
            if value == "~" { return home }
            if value.hasPrefix("~/") { return home + value.dropFirst(1) }
            return value
        }
    }

    // MARK: File shape

    /// `estatecatalog.json`. Every path is absolute: the default database location
    /// and each estate directory. The configuration directory is never
    /// recorded in the file; it is where the file is. An entry's `backend` is
    /// optional and absent for SQLite, so a file written before the field
    /// existed reads as every estate on SQLite, which is what it was.
    struct CatalogFile: Codable, Equatable {
        static let currentVersion = 1
        struct Entry: Codable, Equatable {
            let name: String
            let path: String
            let backend: EstateBackend?
            init(name: String, path: String, backend: EstateBackend? = nil) {
                self.name = name
                self.path = path
                self.backend = backend
            }
        }
        let version: Int
        let defaultLocation: String
        let estates: [Entry]
    }

    /// Write the catalog file atomically from the current records.
    func save() throws {
        let url = Self.catalogURL
        // Transient records never reach the file.
        let file = CatalogFile(
            version: CatalogFile.currentVersion,
            defaultLocation: defaultLocation.path,
            estates: records.filter { $0.kind == .registered }.map {
                CatalogFile.Entry(name: $0.name, path: $0.directory.path,
                                  backend: $0.backend == .sqlite ? nil : $0.backend)
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(file)
            try FileManager.default.createDirectory(at: Self.configurationDirectory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw EstateCatalogError.unwritableCatalog(url: url, detail: String(describing: error))
        }
    }

    private static let logger = Logger(subsystem: MootProductIdentity.Logging.subsystem, category: "GeniusLocusKit")
}
