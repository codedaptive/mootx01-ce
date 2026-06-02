import Foundation
import AriaMCP
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite

// Entry point for the ARIA_MCP stdio server.
//
// Backend selection is driven by the ARIA_MCP_SQLITE_PATH environment
// variable, matching the Rust v2a-server's behavior exactly:
//
//   ARIA_MCP_SQLITE_PATH absent or empty → InMemoryStorage (ephemeral,
//     discarded on exit; byte-identical to prior behavior).
//
//   ARIA_MCP_SQLITE_PATH present and non-empty → SQLiteStorage at that
//     path (WAL-mode, durable across restarts). Parent directories are
//     created automatically. An unusable path (creation failure) causes
//     a clear stderr message and a nonzero exit; no half-open estate
//     state is left behind.
//
// The JSON-RPC wire surface (tools, schemas, methods) is unchanged for
// both backends. Clients do not need to know or care which backend is
// active.
//
// Per ARIA_MCP_SPEC_v0.2 §5, stdout is reserved for JSON-RPC frames;
// all logging routes through Logging.stderr.

@main
struct AriaMCPMain {
    static func main() async {
        await AriaMCPMain.run()
    }

    static func run() async {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-mcp-owner")

        // Read the path variable. No trimming — exact parity with the Rust
        // server's from_env (present and non-empty means the operator
        // intended SQLite; a whitespace-only value is a config error that
        // fails fast below, not a silent fallback to in-memory).
        let rawPath = ProcessInfo.processInfo.environment["ARIA_MCP_SQLITE_PATH"] ?? ""

        let storage: any Storage

        if rawPath.isEmpty {
            // Absent or empty → in-memory ephemeral estate.
            // The estate UUID is fresh each run so the server serves one
            // ephemeral estate per process, matching the v1.0 owner-by-
            // default credential model.
            Logging.stderr.log("ARIA_MCP starting (stdio, in-memory backend)")
            let configuration = EstateConfiguration(estateID: UUID(), backend: .inMemory)
            storage = InMemoryStorage(configuration: configuration)
        } else {
            // Non-empty path → SQLite-backed durable estate.
            let dbURL = URL(fileURLWithPath: rawPath)
            Logging.stderr.log("ARIA_MCP starting (stdio, SQLite backend: \(rawPath))")

            // Create parent directories so the caller does not need to
            // pre-create them. Bare filenames (no directory component) skip
            // creation entirely — exact parity with the Rust server's
            // empty-parent guard (server.rs from_env) — so a read-only cwd
            // does not fail a path that needs no directory created.
            if rawPath.contains("/") {
                let parentDir = dbURL.deletingLastPathComponent()
                do {
                    try FileManager.default.createDirectory(
                        at: parentDir,
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                } catch {
                    fputs(
                        "ARIA_MCP fatal: cannot create parent directory '\(parentDir.path)': \(error)\n",
                        stderr
                    )
                    exit(1)
                }
            }

            // Construct the SQLite storage. busyTimeout of 5.0 seconds is
            // the PersistenceKitSQLite default; sufficient for a single-
            // process server with no concurrent writers.
            let configuration = EstateConfiguration(
                estateID: UUID(),
                backend: .sqlite(url: dbURL, busyTimeout: 5.0)
            )
            do {
                storage = try SQLiteStorage(configuration: configuration)
            } catch {
                fputs(
                    "ARIA_MCP fatal: cannot open SQLite at '\(rawPath)': \(error)\n",
                    stderr
                )
                exit(1)
            }
        }

        let handle: EstateHandle
        do {
            // Estate.create opens the schema idempotently (DrawerStore uses
            // upsert for manifest keys), so calling it on an existing SQLite
            // file is safe: it re-stamps owner_identifier and leaves all
            // other manifest values intact. The subsequent kit.open validates
            // the bitmap layout version and issues the EstateHandle.
            _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
            handle = try await kit.open(storage: storage, owner: owner)
        } catch {
            Logging.stderr.log("ARIA_MCP fatal: failed to open estate: \(error)")
            exit(1)
        }

        let info = ARIA_MCPDispatcher.ServerInfo(name: "ARIA_MCP", version: "0.1.0")
        let tooling = ToolDispatcher(kit: kit, handle: handle)
        let dispatcher = ARIA_MCPDispatcher(info: info, tooling: tooling)
        let server = StdioServer(dispatcher: dispatcher)
        Logging.stderr.log("ARIA_MCP ready (\(dispatcher.tools.count) tools)")
        await server.run()
        Logging.stderr.log("ARIA_MCP exiting (stdin closed)")
    }
}
