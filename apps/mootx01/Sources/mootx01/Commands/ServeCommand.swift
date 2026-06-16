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
import AriaResident
import Darwin

struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Start the ARIA MCP server (stdio, or resident HTTP when --http / MOOTX01_HTTP_PORT is set)."
    )

    @Option(name: .long, help: "Named estate to serve. Default: active estate.")
    var db: String?

    @Option(name: .long, help: "Resident HTTP port on 127.0.0.1 (also MOOTX01_HTTP_PORT). When set, runs the resident daemon (HTTP + Brain pump + telemetry) instead of stdio.")
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

        // Resident HTTP transport when a port is configured (--http flag or
        // MOOTX01_HTTP_PORT); otherwise stdio (the default — existing client
        // configs that run `mootx01` keep working unchanged).
        let residentPort = Self.resolveResidentPort(flag: http, environment: environment)
        Logging.stderr.log("mootx01 serve starting (estate: \(estateName), data dir: \(dataDir.path), transport: \(residentPort.map { "HTTP :\($0)" } ?? "stdio"))")

        // PID file written at start, removed on exit so status/query can detect us.
        let pidURL = dataDir.appendingPathComponent("mootx01.pid", isDirectory: false)
        // Single-writer guard (resident only): the estate has exactly one writer —
        // the resident BrainPump (see ADR-LOOPBACKHTTP-001). Refuse to start the resident
        // daemon if another LIVE process already holds this estate's PID file.
        // stdio is ephemeral and does not pump, so it is not guarded here; a
        // different binary (e.g. the aria-mcp dev build) pointed at the same estate
        // is also not caught by this PID file — documented limitation.
        if residentPort != nil,
           let existing = try? String(contentsOf: pidURL, encoding: .utf8),
           let existingPID = Int32(existing.trimmingCharacters(in: .whitespacesAndNewlines)),
           existingPID != ProcessInfo.processInfo.processIdentifier,
           kill(existingPID, 0) == 0 {
            Logging.stderr.log("mootx01 serve fatal: estate '\(estateName)' is already served by a live process (PID \(existingPID)). One resident writer per estate — stop it first.")
            throw ExitCode.failure
        }
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

        if let port = residentPort {
            // Resident daemon: HTTP transport + Brain pump + telemetry/monitoring
            // gate via the shared AriaResident runner (identical wiring to
            // aria-mcp). The estate is the durable SQLite opened above, so dreaming
            // persists. Telemetry store from ARIA_MCP_STATS_STORE (set by the
            // launchd plist at install).
            let config = AriaResident.ResidentConfig(
                port: port,
                maxBodyBytes: AriaResident.httpMaxBodyBytes(env: environment),
                brainTickMs: AriaResident.brainTickMs(env: environment),
                monitoringPollMs: AriaResident.monitoringPollMs(env: environment),
                statsStorePath: environment["ARIA_MCP_STATS_STORE"]
            )
            Logging.stderr.log("mootx01 serve ready (\(dispatcher.tools.count) tools, resident HTTP on 127.0.0.1:\(port))")
            do {
                try await AriaResident.runResidentDaemon(
                    dispatcher: dispatcher, kit: kit, handle: handle, config: config
                )
            } catch {
                Logging.stderr.log("mootx01 serve fatal: cannot bind HTTP transport on 127.0.0.1:\(port): \(error)")
                throw ExitCode.failure
            }
            Logging.stderr.log("mootx01 serve exiting (HTTP transport stopped)")
        } else {
            let server = StdioServer(dispatcher: dispatcher)
            Logging.stderr.log("mootx01 serve ready (\(dispatcher.tools.count) tools, stdio)")
            await server.run()
            Logging.stderr.log("mootx01 serve exiting (stdin closed)")
        }
    }

    /// Resolve the resident HTTP port: the `--http` flag wins, else
    /// `MOOTX01_HTTP_PORT` from the environment (the launchd plist sets it). nil →
    /// stdio. An out-of-range value is rejected (logged) and falls back to stdio.
    static func resolveResidentPort(flag: Int?, environment: [String: String]) -> UInt16? {
        if let flag {
            guard flag > 0, let port = UInt16(exactly: flag) else {
                Logging.stderr.log("mootx01 serve: --http \(flag) is not a valid TCP port (1–65535); using stdio")
                return nil
            }
            return port
        }
        guard let raw = environment["MOOTX01_HTTP_PORT"], !raw.isEmpty else { return nil }
        guard let port = UInt16(raw), port > 0 else {
            Logging.stderr.log("mootx01 serve: MOOTX01_HTTP_PORT='\(raw)' is not a valid TCP port (1–65535); using stdio")
            return nil
        }
        return port
    }
}
#endif
