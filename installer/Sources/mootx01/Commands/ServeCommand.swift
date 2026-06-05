// ServeCommand.swift
//
// Start the ARIA MCP server over stdio. This is the default behaviour
// when `mootx01` is invoked with stdin as a pipe and no explicit
// subcommand — so existing client configs that use `"command": "mootx01"`
// continue to work without modification.
//
// The serve path is macOS-only: AriaMCP, GeniusLocusKit, and the SQLite
// backend all declare `.macOS(.v15)`. Linux builds include all other
// subcommands (install, uninstall, db, status, query) but omit serve.
// On Linux, MootMain.swift excludes ServeCommand from the subcommand
// list, so this file is only compiled on macOS.

#if os(macOS)
import Foundation
import ArgumentParser
import AriaMCP
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitSQLite
import MootInstallerCore

struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Start the ARIA MCP server (stdio transport)."
    )

    @Option(name: .long, help: "Named estate to serve. Default: active estate.")
    var db: String?

    @Option(name: .long, help: "HTTP port (reserved for future HTTP transport; unused in v1.0).")
    var http: Int?

    func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dataDir = MootPaths.resolveDataDirectory(
            environment: environment,
            homeDirectory: home
        )

        // Resolve estate name: --db flag overrides the active estate pointer.
        let estateName: String
        if let dbFlag = db {
            estateName = dbFlag
        } else {
            estateName = (try? DatabaseManager.activeEstateName(in: dataDir)) ?? "default"
        }

        let estateURL = DatabaseManager.estateURL(for: estateName, in: dataDir)
        Logging.stderr.log("mootx01 serve starting (estate: \(estateName), data dir: \(dataDir.path))")

        // PID file written at start, removed on exit so status/query can detect us.
        let pidURL = dataDir.appendingPathComponent("mootx01.pid", isDirectory: false)
        try? String(ProcessInfo.processInfo.processIdentifier).write(
            to: pidURL, atomically: true, encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: pidURL) }

        // The SQLite backend creates parent dirs and the file on first open;
        // check pre-existence to decide whether to call create (first-run only).
        let isFirstRun = !FileManager.default.fileExists(atPath: estateURL.path)

        let configuration = EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: estateURL, busyTimeout: 5.0)
        )
        let storage: SQLiteStorage
        do {
            storage = try SQLiteStorage(configuration: configuration)
        } catch {
            Logging.stderr.log("mootx01 serve fatal: SQLite open failed: \(error)")
            throw ExitCode.failure
        }

        let owner = OwnerCredentials(
            ownerIdentifier: MootPaths.defaultOwnerIdentifier
        )
        let kit = GeniusLocusKit()
        let handle: EstateHandle
        do {
            if isFirstRun {
                Logging.stderr.log("first-run: creating estate '\(estateName)' at \(estateURL.path)")
                _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
            }
            handle = try await kit.open(storage: storage, owner: owner)
        } catch {
            Logging.stderr.log("mootx01 serve fatal: estate open failed: \(error)")
            throw ExitCode.failure
        }

        let info = ARIA_MCPDispatcher.ServerInfo(
            name: "mootx01",
            version: "1.0.0"
        )
        let tooling = ToolDispatcher(kit: kit, handle: handle)
        let dispatcher = ARIA_MCPDispatcher(info: info, tooling: tooling)
        let server = StdioServer(dispatcher: dispatcher)
        Logging.stderr.log("mootx01 serve ready (\(dispatcher.tools.count) tools)")
        await server.run()
        Logging.stderr.log("mootx01 serve exiting (stdin closed)")
    }
}
#endif
