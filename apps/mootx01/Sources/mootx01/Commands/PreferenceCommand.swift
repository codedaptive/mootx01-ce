// PreferenceCommand.swift
//
// Estate-wide preferences through the catalog: the USER-OWNED on/off
// switches `EstatePreferenceKey` enumerates, each stored in the estate
// manifest as the plain string `on` or `off` and read as `on` when absent.
//
//   preference list                 every key with its current value
//   preference get <key>            one key's current value
//   preference set <key> on|off     write a key, then print it read back
//
// `--db <value>` selects the estate the way `db` does: a bare name is a
// registered estate, a pathname attaches a transient one; absent means the
// active estate. Each subcommand opens the estate for exactly one operation
// and closes it before returning.
//
// No daemon restart follows a `set`: every reader of a preference consults
// the manifest key at fire time, so the resident daemon sees the new value
// on its next pass.

import ArgumentParser
import Foundation
import GeniusLocusKit
import LocusKit
import MootInstallerCore
import MootEstateOpen
import PersistenceKit
import PersistenceKitSQLite

struct PreferenceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "preference",
        abstract: "Read or set an estate-wide preference.",
        discussion: """
        Keys: \(EstatePreferenceKey.allCases.map(\.rawValue).joined(separator: ", "))
        Values: on, off for the switches; fact_extractor takes nuextract or apple. A key that has never been set reads as its default (on; off for chest_contradiction_candidates and chest_recall_diversity; nuextract for fact_extractor).
        """,
        subcommands: [
            PreferenceListCommand.self,
            PreferenceGetCommand.self,
            PreferenceSetCommand.self,
        ]
    )
}

// MARK: - Shared estate open

/// The comma-separated key list quoted by every validation error and the
/// `preference` help text, in `EstatePreferenceKey.allCases` order.
private let allowedKeyList = EstatePreferenceKey.allCases.map(\.rawValue).joined(separator: ", ")

/// Resolves `<key>` to an `EstatePreferenceKey`, refusing anything outside
/// `allCases` with the allowed list in the message.
private func preferenceKey(_ raw: String) throws -> EstatePreferenceKey {
    guard let key = EstatePreferenceKey(rawValue: raw) else {
        throw ValidationError("unknown preference '\(raw)'; allowed: \(allowedKeyList)")
    }
    return key
}

/// Opens the estate `db` selects (absent: the active estate) for one
/// operation, runs `body` against the open handle, and closes the kit and
/// the storage in that order whether or not `body` throws. A fresh database
/// receives the current format stamp and its on-disk estate manifest.
///
/// The open posture (encryption key, plaintext) comes from
/// `EstateOpenPosture.resolve(for:)`; a transient estate keeps its identity
/// key in memory because it has no Keychain record of its own.
private func withOpenEstate<T: Sendable>(
    db: String?,
    _ body: (GeniusLocusKit, EstateHandle) async throws -> T
) async throws -> T {
    let estate = try EstateOpen.catalog(selecting: db).active
    let isNewDatabase = !FileManager.default.fileExists(atPath: estate.databaseURL.path)
    let encryption = try EstateOpenPosture.resolve(for: estate).encryption
    let configuration = EstateConfiguration(
        estateID: UUID(),
        backend: .sqlite(url: estate.databaseURL, busyTimeout: 5.0),
        encryptionConfig: encryption
    )
    let storage = try SQLiteStorage(configuration: configuration)
    let kit = GeniusLocusKit()
    let handle: EstateHandle
    do {
        handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: MootPaths.defaultOwnerIdentifier),
            identityKeyStore: estate.kind == .registered ? nil : InMemoryEstateIdentityKeyStore()
        )
    } catch {
        await storage.close()
        throw error
    }
    do {
        if isNewDatabase {
            // Only a database created by this invocation is stamped current;
            // existing estate formats advance through `mootx01 upgrade`.
            let now = Date()
            try await EstateFormatStore(storage: storage).stamp(.current, now: now)
            if !FileManager.default.fileExists(atPath: estate.manifestURL.path) {
                let posture: EstateManifest.Encryption
                if case .plaintext = encryption.mode { posture = .plaintext } else { posture = .encrypted }
                let manifest = EstateManifest(
                    name: estate.name,
                    schemaVersion: GeniusLocusKitSchema.version,
                    formatVersion: .current,
                    encryption: posture,
                    created: ISO8601DateFormatter().string(from: now))
                try EstateCatalog.writeManifest(manifest, to: estate)
            }
            if case .plaintext = encryption.mode {
                FileHandle.standardError.write(Data(
                    "mootx01 preference: created estate '\(estate.name)' UNENCRYPTED at \(estate.directory.path). Run `mootx01 upgrade` at any time to encrypt it.\n".utf8))
            }
        }
        let result = try await body(kit, handle)
        try await kit.close(handle)
        await storage.close()
        return result
    } catch {
        try? await kit.close(handle)
        await storage.close()
        throw error
    }
}

// MARK: - preference list

struct PreferenceListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Print every estate preference with its current value, one `<key> <value>` per line."
    )

    @Option(name: .long, help: "Estate to read: a registered name, or a pathname to attach a transient estate. Default: the active estate.")
    var db: String?

    func run() async throws {
        let lines = try await withOpenEstate(db: db) { kit, handle -> [String] in
            var lines: [String] = []
            for key in EstatePreferenceKey.allCases {
                let value = try await kit.provisionedPreference(key, for: handle)
                lines.append("\(key.rawValue) \(value.rawValue)")
            }
            return lines
        }
        for line in lines { print(line) }
    }
}

// MARK: - preference get <key>

struct PreferenceGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Print one estate preference's current value (`on` or `off`)."
    )

    @Argument(help: "Preference key. One of: \(allowedKeyList).")
    var key: String

    @Option(name: .long, help: "Estate to read: a registered name, or a pathname to attach a transient estate. Default: the active estate.")
    var db: String?

    func run() async throws {
        let key = try preferenceKey(self.key)
        let value = try await withOpenEstate(db: db) { kit, handle in
            try await kit.provisionedPreference(key, for: handle)
        }
        print(value.rawValue)
    }
}

// MARK: - preference set <key> on|off

struct PreferenceSetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set one estate preference to `on` or `off`. Takes effect immediately: every reader consults the key at fire time, so no daemon restart is needed."
    )

    @Argument(help: "Preference key. One of: \(allowedKeyList).")
    var key: String

    @Argument(help: "New value: on or off (fact_extractor: nuextract or apple).")
    var value: String

    @Option(name: .long, help: "Estate to write: a registered name, or a pathname to attach a transient estate. Default: the active estate.")
    var db: String?

    func run() async throws {
        let key = try preferenceKey(self.key)
        guard let value = EstatePreferenceValue(rawValue: self.value),
              key.allowedValues.contains(value) else {
            let allowed = key.allowedValues.map(\.rawValue).joined(separator: ", ")
            throw ValidationError("invalid value '\(self.value)' for '\(key.rawValue)'; allowed: \(allowed)")
        }
        // Print what the estate holds after the write, not what was asked for,
        // so the output is the read-back proof the value landed.
        let stored = try await withOpenEstate(db: db) { kit, handle in
            try await kit.provisionPreference(key, value, for: handle)
            return try await kit.provisionedPreference(key, for: handle)
        }
        print("\(key.rawValue) \(stored.rawValue)")
    }
}
