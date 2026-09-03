// RedistillCommand.swift
//
// `mootx01 redistill`: force-redistill every active item of an estate and
// rebuild both recall lanes, from the terminal, without a server. The same
// operation the `moot_redistill` MCP tool performs — this command opens the
// estate the way `drain` and `dream` do and dispatches that tool through the
// same ToolDispatcher a serve would, so the call tree and the printed
// result are the server's own. `--dry-run` reports how many rows are stale
// under the active converter and writes nothing.
//
// macOS-only for the same reason as DrainCommand (AriaMCP / GeniusLocusKit /
// SQLite are `.macOS(.v15)`); the Rust port carries the Linux/Windows verb.

#if os(macOS)
import Foundation
import ArgumentParser
import AriaMCP
import GeniusLocusKit
import GeniusLocusKitMigrations
import LocusKit
import PersistenceKit
import PersistenceKitSQLite
import MootInstallerCore

struct RedistillCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "redistill",
        abstract: "Force-redistill every active item of an estate with the active converter and rebuild both recall lanes (BM25 + dense)."
    )

    @Option(name: .long, help: "Named estate to redistill. Default: active estate.")
    var db: String?

    @Flag(name: .long, help: "Report how many rows are stale under the active converter and exit without writing.")
    var dryRun = false

    func run() async throws {
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
        // valid (empty) target. A missing directory is a typo or a wrong
        // data directory.
        guard FileManager.default.fileExists(atPath: estateURL.deletingLastPathComponent().path) else {
            Logging.stderr.log("mootx01 redistill fatal: estate '\(estateName)' not found at \(estateURL.path)")
            throw ExitCode.failure
        }

        // At-rest posture: the same shared decision serve, drain and dream use.
        let encryption: EstateEncryptionConfig
        do {
            encryption = try EstateKeyProvider.resolveOpenPosture(for: estateURL).encryption
        } catch {
            Logging.stderr.log("mootx01 redistill fatal: estate encryption key unavailable: \(error)")
            throw ExitCode.failure
        }
        let configuration = EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: estateURL, busyTimeout: 5.0),
            encryptionConfig: encryption
        )
        let storage: SQLiteStorage
        do {
            storage = try SQLiteStorage(configuration: configuration)
        } catch {
            Logging.stderr.log("mootx01 redistill fatal: SQLite open failed: \(error)")
            throw ExitCode.failure
        }

        let owner = OwnerCredentials(ownerIdentifier: MootPaths.defaultOwnerIdentifier)
        let kit = GeniusLocusKit()
        let handle: EstateHandle
        do {
            handle = try await kit.open(storage: storage, owner: owner)
            _ = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: Date())
            try await kit.wireGLKSubstores(for: handle, backingStorage: storage)
        } catch {
            Logging.stderr.log("mootx01 redistill fatal: estate open/wiring failed: \(error)")
            throw ExitCode.failure
        }

        // The "distillation" drain entry counts rows the currency rule calls
        // stale under the active converter — the rows `mootx01 upgrade` would
        // regenerate. The force sweep rewrites every active item regardless.
        let stale = ((try? await kit.drainStatuses(handle)) ?? [])
            .first { $0.name == "distillation" }?.pending ?? 0
        print("estate: \(estateName)")
        print("converter: \(GeniusLocusKit.distillationConverterID)")
        print("rows stale under the active converter: \(stale)")
        if dryRun {
            print("dry run: no rows written")
            try await kit.close(handle)
            await storage.close()
            return
        }

        let start = Date()
        let dispatcher = ToolDispatcher(kit: kit, handle: handle, serverIdentity: "mootx01")
        let result = try await dispatcher.dispatch(
            name: RedistillCommand.toolName, arguments: .object([:]))
        let (text, isError) = Self.firstText(of: result)
        print(text)
        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "elapsed: %.1fs", elapsed))
        try await kit.close(handle)
        await storage.close()
        if isError { throw ExitCode.failure }
    }

    /// The MCP tool this verb dispatches. One name, one implementation.
    static let toolName = "moot_redistill"

    /// The first text block of a tool result and its `isError` flag. A result
    /// without a text block prints as an empty line rather than crashing;
    /// the flag is what decides the exit status.
    static func firstText(of result: JSONValue) -> (text: String, isError: Bool) {
        guard case .object(let object) = result else { return ("", true) }
        var isError = false
        if case .bool(let flag)? = object["isError"] { isError = flag }
        var text = ""
        if case .array(let blocks)? = object["content"],
           case .object(let first)? = blocks.first,
           case .string(let value)? = first["text"] {
            text = value
        }
        return (text, isError)
    }
}
#endif
