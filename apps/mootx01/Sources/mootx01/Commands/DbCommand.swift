// DbCommand.swift
//
// Named estate lifecycle: create, list, open (set active), delete.
// Estates live at ~/Library/Application Support/MOOTx01/databases/<name>/.
// The active estate pointer is stored in config.json.

import ArgumentParser
import Foundation
import MootInstallerCore
import PersistenceKitSQLite

struct DbCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "db",
        abstract: "Manage named estate databases.",
        subcommands: [
            DbCreateCommand.self,
            DbListCommand.self,
            DbOpenCommand.self,
            DbDeleteCommand.self,
        ]
    )
}

// MARK: - db create <name>

struct DbCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new named estate."
    )

    @Argument(help: "Name for the new estate.")
    var name: String

    /// Same opt-out shape as `mootx01 install --no-encrypt`, deliberately: the two
    /// estate-creating surfaces must not disagree about the default.
    @Flag(name: .long, help: "Create the estate WITHOUT at-rest encryption. The estate database is stored unencrypted. Default is encrypted (SQLCipher whole-database, key held in the Keychain). Run `mootx01 upgrade` at any time to encrypt an unencrypted estate.")
    var noEncrypt: Bool = false

    func run() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        let dataDir = MootPaths.resolveDataDirectory(environment: env, homeDirectory: home)

        try DatabaseManager.createEstate(name: name, in: dataDir)

        // createEstate makes the estate DIRECTORY; the substrate writes the SQLite
        // file lazily on first open. So the encryption posture is settled here,
        // before the file exists, in the same two ways install settles it.
        let estateURL = DatabaseManager.estateURL(for: name, in: dataDir)
        if noEncrypt {
            try EstateKeyProvider.writeEncryptionOptOut(forEstateAt: estateURL)
            print("Created estate '\(name)' (UNENCRYPTED, --no-encrypt).")
            print("  Run `mootx01 upgrade` at any time to encrypt it.")
        } else {
            #if os(macOS)
            // Provision the key NOW rather than at first open. Two reasons: a
            // failure surfaces here, while `db create` can still be retried and
            // nothing has been half-made; and the delete path disposes the key by
            // deriving the same account from this same estate URL, so provisioning
            // eagerly is what keeps create and delete symmetric instead of leaving
            // a key to be minted later by whoever opens the estate first.
            do {
                // A re-created estate name can inherit a stale --no-encrypt
                // marker from an earlier estate at the same path. The open
                // posture honors the marker for an absent file — so without
                // this sweep, first open would create the estate PLAINTEXT
                // even though a key was just provisioned and the user did not
                // opt out (stale-marker downgrade, Codex fe2cf887).
                if try EstateKeyProvider.removeEncryptionOptOut(forEstateAt: estateURL) {
                    print("Removed a stale --no-encrypt marker for '\(name)'; the estate will be encrypted (the default).")
                }
                _ = try EstateKeyProvider.provideKey(for: estateURL)
                print("Created estate '\(name)' (encrypted at rest).")
            } catch {
                // Fail closed and leave nothing behind. An estate directory whose
                // key could not be provisioned would otherwise be created as
                // plaintext on first open, silently contradicting the default the
                // user did not opt out of.
                try? FileManager.default.removeItem(at: estateURL.deletingLastPathComponent())
                throw ValidationError(
                    "could not prepare the encryption key for estate '\(name)': \(error). Nothing was created. Use --no-encrypt to create an unencrypted estate.")
            }
            #else
            print("Created estate '\(name)'.")
            #endif
        }
        print("Run `mootx01 db open \(name)` to make it the active estate.")
    }
}

// MARK: - db list

struct DbListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all known estates."
    )

    func run() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        let dataDir = MootPaths.resolveDataDirectory(environment: env, homeDirectory: home)

        let estates = DatabaseManager.listEstates(in: dataDir)
        let active = (try? DatabaseManager.activeEstateName(in: dataDir)) ?? "default"

        if estates.isEmpty {
            print("No estates found. Run `mootx01 serve` to create the default estate.")
            return
        }

        print("Estates:")
        for name in estates {
            let marker = name == active ? " (active)" : ""
            print("  \(name)\(marker)")
        }
    }
}

// MARK: - db open <name>

struct DbOpenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Set the active estate (used by serve and status)."
    )

    @Argument(help: "Estate name to activate.")
    var name: String

    func run() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        let dataDir = MootPaths.resolveDataDirectory(environment: env, homeDirectory: home)

        // Detect estate presence by the directory, not the SQLite file — the file
        // is written lazily on first serve, but the directory is created by db create.
        // This is consistent with listEstates and the Rust port's open implementation.
        let estateDir = DatabaseManager.estateURL(for: name, in: dataDir)
            .deletingLastPathComponent()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: estateDir.path, isDirectory: &isDir),
              isDir.boolValue else {
            print("Estate '\(name)' not found. Run `mootx01 db list` to see available estates.")
            throw ExitCode.failure
        }

        try DatabaseManager.setActiveEstate(name, in: dataDir)
        print("Active estate set to '\(name)'.")
    }
}

// MARK: - db delete <name>

struct DbDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a named estate and its database files."
    )

    @Argument(help: "Estate name to delete. Cannot delete 'default' (use uninstall --purge).")
    var name: String

    @Flag(name: .shortAndLong, help: "Skip confirmation prompt.")
    var yes: Bool = false

    func run() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        let dataDir = MootPaths.resolveDataDirectory(environment: env, homeDirectory: home)

        if !yes {
            print("Delete estate '\(name)' and all its data? This is irreversible.")
            print("Type 'yes' to confirm: ", terminator: "")
            guard readLine()?.trimmingCharacters(in: .whitespaces).lowercased() == "yes" else {
                print("Aborted.")
                return
            }
        }

        try DatabaseManager.deleteEstate(name: name, in: dataDir)

        // Dispose this estate's whole-file encryption key so it never outlives the
        // data it protected — the Apple analogue of removing the Rust `db.key`
        // with the estate directory. Apple-only: the key lives in the Keychain,
        // keyed by the estate file path the openers used. Best-effort: the data is
        // already gone, so a Keychain error is a warning, not a command failure.
        #if canImport(Security)
        let estateURL = DatabaseManager.estateURL(for: name, in: dataDir)
        // Delete from both the shared access group (current) AND the
        // legacy default group (estates created before #94). Best-effort
        // on both — a missing key is not an error.
        for group in ["com.codedaptive.mootx01.shared", nil] as [String?] {
            do {
                try KeychainKeyStore(
                    service: "com.codedaptive.mootx01",
                    estateURL: estateURL,
                    accessGroup: group
                ).deleteKey()
            } catch {
                if group != nil {
                    FileHandle.standardError.write(Data(
                        "warning: could not remove Keychain key (group=\(group ?? "default")): \(error)\n".utf8))
                }
            }
        }
        #endif

        print("Estate '\(name)' deleted.")
    }
}
