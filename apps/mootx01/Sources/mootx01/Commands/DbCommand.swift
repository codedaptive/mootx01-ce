// DbCommand.swift
//
// Named estate lifecycle: create, list, open (set active), delete, and the
// estate-level settings that live in the estate itself (composition).
// Estates live at ~/Library/Application Support/MOOTx01/databases/<name>/.
// The active estate pointer is stored in config.json.

import ArgumentParser
import Foundation
import MootInstallerCore
import PersistenceKitSQLite
#if os(macOS)
import AriaMCP
import GeniusLocusKit
import GeniusLocusKitMigrations
import LocusKit
import PersistenceKit
#endif

struct DbCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "db",
        abstract: "Manage named estate databases.",
        subcommands: [
            DbCreateCommand.self,
            DbListCommand.self,
            DbOpenCommand.self,
            DbDeleteCommand.self,
        ] + estateSettingSubcommands
    )

    /// Subcommands that open the estate through GeniusLocusKit. macOS-only
    /// for the same reason as `redistill`: the kits are `.macOS`; the Rust
    /// port carries the Linux/Windows verb.
    #if os(macOS)
    static let estateSettingSubcommands: [ParsableCommand.Type] = [DbCompositionCommand.self]
    #else
    static let estateSettingSubcommands: [ParsableCommand.Type] = []
    #endif
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

// MARK: - db composition [--db <name>] [--set <policy-id>]

#if os(macOS)
/// `mootx01 db composition`: show or change the estate's stored index
/// composition policy, which names the text each search index lane is built
/// from (lexical and dense sources; id `lex=<source>;dense=<source>`). The
/// policy is an estate setting (LocusKit manifest key
/// `index_composition_policy`), read by GeniusLocusKit at every open.
///
/// Without `--set` the command prints the stored id. With `--set` it
/// validates the id before opening anything, writes the setting, wires the
/// Corpus under the new policy with the rebuild committed, and runs the same
/// `reindexCorpus` the upgrade convergence step runs, so the stored policy
/// and the index rows never disagree; it prints the rows reindexed and exits
/// non-zero on any failure. Opens the estate the way `redistill` does.
struct DbCompositionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "composition",
        abstract: "Show or change the estate's stored index composition policy (which text each search index lane is built from) and rebuild the lanes under it."
    )

    @Option(name: .long, help: "Named estate. Default: active estate.")
    var db: String?

    @Option(name: .long, help: "Store this policy id (lex=<source>;dense=<source>) and rebuild every index lane under it.")
    var set: String?

    func run() async throws {
        // A malformed id is refused before anything is opened or written.
        let requestedID: String?
        if let set {
            guard let normalized = GeniusLocusKit.indexCompositionPolicyID(parsing: set) else {
                Logging.stderr.log("mootx01 db composition fatal: '\(set)' is not an index composition policy id (expected lex=<source>;dense=<source>, e.g. lex=original;dense=distilled)")
                throw ExitCode.failure
            }
            requestedID = normalized
        } else {
            requestedID = nil
        }

        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dataDir = MootPaths.resolveDataDirectory(environment: environment, homeDirectory: home)
        let estateName: String
        if let dbFlag = db {
            estateName = dbFlag
        } else {
            estateName = (try? DatabaseManager.activeEstateName(in: dataDir)) ?? "default"
        }
        let estateURL: URL
        if let envPath = environment["ARIA_MCP_SQLITE_PATH"], !envPath.isEmpty {
            estateURL = URL(fileURLWithPath: envPath)
        } else {
            estateURL = DatabaseManager.estateURL(for: estateName, in: dataDir)
        }
        // `mootx01 db create` makes the estate directory; the substrate writes
        // the SQLite file on first open, so a never-opened estate is still a
        // valid target. A missing directory is a typo or a wrong data directory.
        guard FileManager.default.fileExists(atPath: estateURL.deletingLastPathComponent().path) else {
            Logging.stderr.log("mootx01 db composition fatal: estate '\(estateName)' not found at \(estateURL.path)")
            throw ExitCode.failure
        }

        let owner = OwnerCredentials(ownerIdentifier: MootPaths.defaultOwnerIdentifier)
        guard let requestedID else {
            // Show is a read: the daemon keeps serving.
            do {
                let storedID = try await Self.storedPolicyID(estateURL: estateURL, owner: owner)
                print("estate: \(estateName)")
                print("index_composition_policy: \(storedID ?? "none")")
            } catch {
                Logging.stderr.log("mootx01 db composition fatal: \(error)")
                throw ExitCode.failure
            }
            return
        }

        // The rebuild rewrites every index row while a serving daemon would
        // keep encoding captures under the policy it opened with, the
        // single-writer hazard `mootx01 upgrade` already guards:
        // ResidentDaemonQuiesce stops the daemon around the rebuild only when
        // this data directory is the resident estate and restarts it
        // afterwards; a clone is rebuilt with the daemon untouched. A nil
        // result means the daemon would not stop; nothing was written.
        let outcome = await ResidentDaemonQuiesce.run(
            dataDirectory: dataDir,
            residentDataDirectory: MootPaths.residentDataDirectory(homeDirectory: home),
            step: "index composition rebuild",
            daemon: .launchd(homeDirectory: home)
        ) { () async -> Result<RebuildReport, CompositionFailure> in
            await Self.rebuild(
                estateURL: estateURL, owner: owner, estateName: estateName, requestedID: requestedID)
        }
        guard let outcome else {
            Logging.stderr.log("mootx01 db composition fatal: the resident daemon would not stop; nothing was changed. Stop it and run `mootx01 db composition --set` again")
            throw ExitCode.failure
        }
        switch outcome {
        case .success(let report):
            for line in report.lines { print(line) }
            if let stale = report.stale {
                Logging.stderr.log("mootx01 db composition fatal: rows still carry another policy after the rebuild (\(stale))")
                throw ExitCode.failure
            }
        case .failure(let failure):
            Logging.stderr.log("mootx01 db composition fatal: \(failure)")
            throw ExitCode.failure
        }
    }

    /// Why a show or a rebuild stopped, in the operator-facing wording each
    /// stage reports.
    private enum CompositionFailure: Error, CustomStringConvertible {
        case keyUnavailable(any Error)
        case sqliteOpen(any Error)
        case estateOpen(any Error)
        case work(any Error)

        var description: String {
            switch self {
            case .keyUnavailable(let error): return "estate encryption key unavailable: \(error)"
            case .sqliteOpen(let error): return "SQLite open failed: \(error)"
            case .estateOpen(let error): return "estate open failed: \(error)"
            case .work(let error): return "\(error)"
            }
        }
    }

    /// The lines `--set` prints, and the stale-row detail when rows still
    /// carry another policy after the rebuild.
    private struct RebuildReport {
        let lines: [String]
        let stale: String?
    }

    /// Open the estate's SQLite under the shared at-rest posture serve, drain
    /// and redistill use, then the kit plus the migration catalog (which
    /// seeds the setting on an estate that predates it).
    private static func openEstate(
        estateURL: URL, owner: OwnerCredentials
    ) async throws -> (kit: GeniusLocusKit, handle: EstateHandle, storage: SQLiteStorage) {
        let encryption: EstateEncryptionConfig
        do {
            encryption = try EstateKeyProvider.resolveOpenPosture(for: estateURL).encryption
        } catch {
            throw CompositionFailure.keyUnavailable(error)
        }
        let storage: SQLiteStorage
        do {
            storage = try SQLiteStorage(configuration: EstateConfiguration(
                estateID: UUID(),
                backend: .sqlite(url: estateURL, busyTimeout: 5.0),
                encryptionConfig: encryption))
        } catch {
            throw CompositionFailure.sqliteOpen(error)
        }
        let kit = GeniusLocusKit()
        do {
            let handle = try await kit.open(storage: storage, owner: owner)
            _ = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: Date())
            return (kit, handle, storage)
        } catch {
            await storage.close()
            throw CompositionFailure.estateOpen(error)
        }
    }

    /// The stored policy id through a plain kit open. Twin of the Rust show arm.
    private static func storedPolicyID(estateURL: URL, owner: OwnerCredentials) async throws -> String? {
        let (kit, handle, storage) = try await openEstate(estateURL: estateURL, owner: owner)
        do {
            let storedID = try await kit.storedIndexCompositionPolicyID(for: handle)
            try await kit.close(handle)
            await storage.close()
            return storedID
        } catch {
            try? await kit.close(handle)
            await storage.close()
            throw CompositionFailure.work(error)
        }
    }

    /// Store the setting and rebuild every index lane under it. 1. Store the
    /// setting. 2. Wire the Corpus under it with the rebuild committed (its
    /// rows still carry the old id). 3. Drain the encode queue. 4. Rebuild
    /// every lane. 5. Count the rows under each id. Twin of the Rust
    /// `run_composition_on_estate` `--set` arm.
    private static func rebuild(
        estateURL: URL, owner: OwnerCredentials, estateName: String, requestedID: String
    ) async -> Result<RebuildReport, CompositionFailure> {
        let opened: (kit: GeniusLocusKit, handle: EstateHandle, storage: SQLiteStorage)
        do {
            opened = try await openEstate(estateURL: estateURL, owner: owner)
        } catch let failure as CompositionFailure {
            return .failure(failure)
        } catch {
            return .failure(.estateOpen(error))
        }
        let (kit, handle, storage) = opened
        let start = Date()
        do {
            let storedID = try await kit.setIndexCompositionPolicy(id: requestedID, for: handle)
            try await kit.wireGLKSubstores(for: handle, backingStorage: storage, reindexPending: true)
            // Drain to empty BEFORE the rebuild. A job left pending by an
            // earlier process (a capture whose encode had not run when that
            // process exited) would otherwise be indexed by this command's
            // own drain worker while `reindexCorpus` runs, and the
            // interleaving would decide the row's final state. Drained here,
            // every pending job is indexed under the stored setting first;
            // the rebuild then rewrites every row.
            try await kit.awaitEncodeDrain(for: handle)
            try await kit.reindexCorpus(handle: handle, now: Date())
            let counts = try await kit.indexCompositionPolicyRowCounts(for: handle)
            try await kit.close(handle)
            await storage.close()
            let reindexed = counts[storedID] ?? 0
            let stale = counts.filter { $0.key != storedID }
            let lines = [
                "estate: \(estateName)",
                "index_composition_policy: \(storedID)",
                "rows reindexed: \(reindexed)",
                String(format: "elapsed: %.1fs", Date().timeIntervalSince(start)),
            ]
            let detail = stale.isEmpty
                ? nil
                : stale.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ")
            return .success(RebuildReport(lines: lines, stale: detail))
        } catch {
            try? await kit.close(handle)
            await storage.close()
            return .failure(.work(error))
        }
    }
}
#endif
