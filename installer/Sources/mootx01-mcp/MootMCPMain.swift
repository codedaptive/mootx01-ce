// MootMCPMain.swift
//
// Entry point for `mootx01-mcp`, the user-installed stdio MCP
// server. Wraps the published AriaMCP library on top of a
// persistent SQLite-backed GeniusLocusKit estate under the user's
// data directory.
//
// LAUNCH-05 Part 2 ("first-run creates MOOT on MDCC default") is
// the conditional create-or-open path below: when estate.sqlite is
// absent the binary calls LocusKit.Estate.create to bootstrap the
// schema and stamp the manifest before opening; otherwise it just
// opens the existing estate. Either way the same stdio server is
// then run, so a client that launched mootx01-mcp on the user's
// very first run sees a working MOOT identically to every
// subsequent run.
//
// "On the MDCC default" — per LAUNCH_PLAN.md §EideticLib the
// private MDCC scheme is the built-in classification that ships
// inside the kits; nothing extra is set up here for it. The bar
// is that the estate the client reaches uses the default scheme,
// which is what LocusKit + GeniusLocusKit do out of the box on a
// fresh SQLite estate.
//
// Per ARIA_MCP_SPEC §5 (and to keep this binary consistent with
// the `aria-mcp` spike), stdout is reserved for JSON-RPC frames
// and every human-readable line goes to stderr via
// AriaMCP.Logging.stderr.

import Foundation
import AriaMCP
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitSQLite
import MootInstallerCore

@main
struct MootMCPMain {
    static func main() async {
        await MootMCPMain.run()
    }

    static func run() async {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dataDir = MootPaths.resolveDataDirectory(
            environment: environment,
            homeDirectory: home
        )
        let estateURL = MootPaths.estateURL(in: dataDir)
        Logging.stderr.log("mootx01-mcp starting (data dir \(dataDir.path))")

        // The SQLite backend creates the parent directory and the
        // file on first open (PersistenceKitSQLite.SQLiteConnection),
        // but we need to know whether the file pre-existed so we
        // call create on first-run only. Check before constructing
        // the backend.
        let isFirstRun = !FileManager.default.fileExists(atPath: estateURL.path)

        let configuration = EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: estateURL, busyTimeout: 5.0)
        )
        let storage: SQLiteStorage
        do {
            storage = try SQLiteStorage(configuration: configuration)
        } catch {
            Logging.stderr.log("mootx01-mcp fatal: SQLite open failed: \(error)")
            exit(1)
        }

        let owner = OwnerCredentials(
            ownerIdentifier: MootPaths.defaultOwnerIdentifier
        )
        let kit = GeniusLocusKit()
        let handle: EstateHandle
        do {
            if isFirstRun {
                Logging.stderr.log("first-run: creating MOOT at \(estateURL.path)")
                _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
            }
            handle = try await kit.open(storage: storage, owner: owner)
        } catch {
            Logging.stderr.log("mootx01-mcp fatal: estate open failed: \(error)")
            exit(1)
        }

        let info = ARIA_MCPDispatcher.ServerInfo(
            name: "mootx01-mcp",
            version: "0.1.0"
        )
        let tooling = ToolDispatcher(kit: kit, handle: handle)
        let dispatcher = ARIA_MCPDispatcher(info: info, tooling: tooling)
        let server = StdioServer(dispatcher: dispatcher)
        Logging.stderr.log("mootx01-mcp ready (\(dispatcher.tools.count) tools)")
        await server.run()
        Logging.stderr.log("mootx01-mcp exiting (stdin closed)")
    }
}
