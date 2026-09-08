// DbCommand.swift
//
// Estate lifecycle through the catalog: create, register, unregister, list,
// open (activate), delete.
//
// Every estate is a directory named for the estate, holding its files and
// its manifest (`estate.json`). `EstateCatalog` is the only thing that knows
// where estates are. `<value>` arguments follow the catalog's one rule: a
// bare name means the default database location under the configuration
// directory; a pathname means exactly that place.
//
//   db create <name>            create at the default location and register it
//   db create <dir>/<name>      create at that place, unregistered and therefore
//                               plaintext (`--no-encrypt` required); `--db
//                               <dir>/<name>` attaches it
//   db register <value>         register an estate that already exists
//   db unregister <name>        forget a registered estate; files untouched
//   db list                     the catalog, active first
//   db open <name>              make a registered estate the active one
//   db delete <name>            remove a registered estate's files and record

import ArgumentParser
import Foundation
import GeniusLocusKit
import MootInstallerCore

struct DbCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "db",
        abstract: "Manage estate databases.",
        subcommands: [
            DbCreateCommand.self,
            DbRegisterCommand.self,
            DbUnregisterCommand.self,
            DbListCommand.self,
            DbOpenCommand.self,
            DbDeleteCommand.self,
        ]
    )
}

// MARK: - db create <value>

struct DbCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new estate: a name at the default location (registered), or <dir>/<name> at that place (unregistered)."
    )

    @Argument(help: "Estate name, or <dir>/<name>.")
    var value: String

    /// Same opt-out shape as `mootx01 install --no-encrypt`, deliberately: the two
    /// estate-creating surfaces must not disagree about the default.
    @Flag(name: .long, help: "Create the estate WITHOUT at-rest encryption. The estate database is stored unencrypted. Default is encrypted (SQLCipher whole-database, key held in the Keychain). Run `mootx01 upgrade` at any time to encrypt an unencrypted estate.")
    var noEncrypt: Bool = false

    func run() async throws {
        var catalog = try EstateCatalog.open()
        let selector = try EstateCatalog.EstateSelector(value)
        let registered = selector.path == nil
        let directory = selector.directory ?? catalog.directory(forBareName: selector.name)
        let record = EstateRecord(name: selector.name, directory: directory,
                                  kind: registered ? .registered : .transient)

        if registered, catalog.record(named: selector.name) != nil {
            throw ValidationError("an estate named '\(selector.name)' is already registered")
        }
        // Only a registered estate, owned by this machine, may be encrypted with
        // a Keychain-held key. An unregistered estate is plaintext by definition.
        if !registered, !noEncrypt {
            throw ValidationError(
                "'\(record.directory.path)' would be an unregistered estate, and only a registered estate can be encrypted. Pass --no-encrypt, or create it by name and register it.")
        }
        if FileManager.default.fileExists(atPath: record.directory.path) {
            throw ValidationError("'\(record.directory.path)' already exists; delete it or choose another name")
        }

        // The directory and the manifest are the estate's identity on disk; the
        // substrate writes the SQLite file lazily on first open. The encryption
        // posture is settled here, in the manifest, before the file exists —
        // the same record install writes.
        try FileManager.default.createDirectory(at: record.directory, withIntermediateDirectories: true)
        let manifest = EstateManifest(
            name: record.name,
            schemaVersion: GeniusLocusKitSchema.version,
            formatVersion: .current,
            encryption: noEncrypt ? .plaintext : .encrypted,
            created: ISO8601DateFormatter().string(from: Date()))
        func failClosed(_ error: any Error) -> ValidationError {
            // Leave nothing behind. An estate directory whose key could not be
            // provisioned would otherwise be opened as plaintext later, silently
            // contradicting the default the user did not opt out of.
            try? FileManager.default.removeItem(at: record.directory)
            return ValidationError(
                "could not prepare estate '\(record.name)': \(error). Nothing was created. Use --no-encrypt to create an unencrypted estate.")
        }
        do {
            try EstateCatalog.writeManifest(manifest, to: record)
        } catch {
            throw failClosed(error)
        }

        // The manifest written above is the record of the posture. Plaintext
        // needs nothing more; an encrypted registered estate gets its key now.
        if !noEncrypt {
            #if os(macOS)
            // Provision the key NOW rather than at first open: a failure surfaces
            // here while nothing is half-made, and delete disposes the key by
            // deriving the same account from this same estate URL, which keeps
            // create and delete symmetric.
            do { _ = try EstateOpenPosture.provideKey(for: record) } catch { throw failClosed(error) }
            #endif
        }

        if registered {
            do { try catalog.register(name: record.name, directory: record.directory) } catch { throw failClosed(error) }
        }

        let posture = noEncrypt ? "UNENCRYPTED, --no-encrypt" : "encrypted at rest"
        print("Created estate '\(record.name)' at \(record.directory.path) (\(posture)).")
        if noEncrypt { print("  Run `mootx01 upgrade` at any time to encrypt it.") }
        if registered {
            print("Run `mootx01 db open \(record.name)` to make it the active estate.")
        } else {
            print("Unregistered: attach it with `--db \(record.directory.path)`, or `mootx01 db register \(record.directory.path)`.")
        }
    }
}

// MARK: - db register <value>

struct DbRegisterCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "register",
        abstract: "Register an existing estate in the catalog. Its files are not touched."
    )

    @Argument(help: "Estate name (at the default location) or <dir>/<name>.")
    var value: String

    func run() async throws {
        var catalog = try EstateCatalog.open()
        let selector = try EstateCatalog.EstateSelector(value)
        let directory = selector.directory ?? catalog.directory(forBareName: selector.name)
        let record = EstateRecord(name: selector.name, directory: directory)
        guard FileManager.default.fileExists(atPath: record.manifestURL.path) else {
            throw ValidationError("no estate at \(record.directory.path): its \(EstateCatalogNames.manifest) is missing")
        }
        _ = try EstateCatalog.readManifest(of: record)   // names this estate, files inside, no redirects
        try catalog.register(name: record.name, directory: record.directory)
        print("Registered estate '\(record.name)' at \(record.directory.path).")
    }
}

// MARK: - db unregister <name>

struct DbUnregisterCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unregister",
        abstract: "Forget a registered estate. Its files are not touched; `--db <dir>/<name>` still attaches it."
    )

    @Argument(help: "Registered estate name.")
    var name: String

    func run() async throws {
        var catalog = try EstateCatalog.open()
        guard let record = catalog.record(named: name) else {
            throw ValidationError("no estate named '\(name)' is registered. Run `mootx01 db list`.")
        }
        try catalog.remove(name: name)
        print("Unregistered estate '\(name)'; its files remain at \(record.directory.path).")
    }
}

// MARK: - db list

struct DbListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the registered estates, active first."
    )

    func run() async throws {
        let catalog = try EstateCatalog.open()
        print("Estates (default location \(catalog.defaultLocation.path)):")
        for (index, record) in catalog.records.enumerated() {
            let marker = index == 0 ? " (active)" : ""
            print("  \(record.name)\(marker)  \(record.directory.path)")
        }
    }
}

// MARK: - db open <name>

struct DbOpenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Make a registered estate the active one (used by serve, drain, dream, query and status)."
    )

    @Argument(help: "Registered estate name.")
    var name: String

    func run() async throws {
        var catalog = try EstateCatalog.open()
        let selector = try EstateCatalog.EstateSelector(name)
        guard selector.path == nil else {
            throw ValidationError("`db open` takes a registered name; register '\(name)' first with `mootx01 db register`, or attach it for one invocation with `--db \(name)`.")
        }
        guard catalog.record(named: selector.name) != nil else {
            throw ValidationError("no estate named '\(selector.name)' is registered. Run `mootx01 db list`.")
        }
        try catalog.activate(name: selector.name)
        print("Active estate set to '\(selector.name)'.")
    }
}

// MARK: - db delete <name>

struct DbDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a registered estate: its files and its record. The active estate cannot be deleted."
    )

    @Argument(help: "Registered estate name. Cannot delete the active estate (activate another first) or 'default' (use uninstall --purge).")
    var name: String

    @Flag(name: .shortAndLong, help: "Skip confirmation prompt.")
    var yes: Bool = false

    func run() async throws {
        var catalog = try EstateCatalog.open()
        guard let record = catalog.record(named: name) else {
            throw ValidationError("no estate named '\(name)' is registered. Run `mootx01 db list`.")
        }
        if name == EstateCatalog.defaultName {
            throw ValidationError("cannot delete 'default' (use uninstall --purge).")
        }
        if catalog.active.name == name {
            throw ValidationError("'\(name)' is the active estate; run `mootx01 db open <other>` first.")
        }

        if !yes {
            print("Delete estate '\(name)' at \(record.directory.path) and all its data? This is irreversible.")
            print("Type 'yes' to confirm: ", terminator: "")
            guard readLine()?.trimmingCharacters(in: .whitespaces).lowercased() == "yes" else {
                print("Aborted.")
                return
            }
        }

        // Files first, then the record: a failure mid-way leaves a record that
        // still points at whatever remains, never an orphan directory nobody
        // can find.
        try EstateCatalog.verifyFilesStayInside(record)
        try FileManager.default.removeItem(at: record.directory)

        // Dispose this estate's whole-file encryption key so it never outlives the
        // data it protected. Keyed by the estate file path the openers used.
        // Best-effort: the data is already gone, so a Keychain error is a warning.
        for error in EstateOpenPosture.disposeKey(databaseURL: record.databaseURL) {
            FileHandle.standardError.write(Data("warning: could not remove Keychain key: \(error)\n".utf8))
        }

        try catalog.remove(name: name)
        print("Estate '\(name)' deleted.")
    }
}
