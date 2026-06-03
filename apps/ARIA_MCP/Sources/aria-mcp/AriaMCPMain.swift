import Foundation
import AriaMCP
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
import PersistenceKitPostgreSQL

// Entry point for the ARIA_MCP stdio server.
//
// Backend selection follows a four-state precedence ladder driven by two
// environment variables. No trimming on either variable — a whitespace-only
// value is treated as a non-empty string and fails fast as a config error,
// not a silent fallback (byte-for-byte parity with the Rust server's from_env).
//
// Precedence table (evaluated at startup, in order):
//
//   Both ARIA_MCP_POSTGRES_URL and ARIA_MCP_SQLITE_PATH set (non-empty)
//     → Ambiguous config: clear stderr message naming both vars; exit 1.
//       Never pick silently — the operator must resolve the ambiguity.
//
//   Only ARIA_MCP_POSTGRES_URL set (non-empty)
//     → PostgreSQLStorage at that connection string (pooled, lazy — the
//       pool opens connections on first use; a connectivity failure
//       surfaces at Estate.create/kit.open, before any tool is dispatched).
//       Pool defaults: poolSize=10, connectionTimeout=5s, idleTimeout=300s
//       (PersistenceKit BackendConfiguration defaults; read from
//       EstateConfiguration.BackendConfiguration.postgresql parameters).
//
//   Only ARIA_MCP_SQLITE_PATH set (non-empty)
//     → SQLiteStorage at that path (WAL-mode, durable across restarts).
//       Parent directories are created automatically. An unusable path
//       causes a clear stderr message and a nonzero exit.
//
//   Neither set (both absent or empty)
//     → InMemoryStorage (ephemeral, discarded on exit; v1.0 default).
//
// The JSON-RPC wire surface (tools, schemas, methods) is unchanged for all
// backends. Clients do not need to know or care which backend is active.
//
// Per ARIA_MCP_SPEC_v0.2 §5, stdout is reserved for JSON-RPC frames;
// all logging routes through Logging.stderr.
//
// Lazy-vs-probe decision (PostgreSQL): PostgreSQLStorage uses a lazy
// connection pool — no TCP connection is opened in the constructor.
// The first real I/O occurs at Estate.create (which calls storage.open),
// so an unreachable server surfaces at startup before any tool call is
// dispatched. No explicit probe is needed; the estate-open call IS the
// probe. This is the same fail-fast point as SQLite (SQLiteStorage.init
// is the probe there). Both backends fail fast at the same lifecycle stage.

@main
struct AriaMCPMain {
    static func main() async {
        await AriaMCPMain.run()
    }

    static func run() async {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-mcp-owner")

        // Read both env vars. No trimming on either — exact parity with the
        // Rust server's from_env. Present and non-empty → the operator
        // intended that backend; a whitespace-only value is a config error
        // that fails fast, not a silent fallback.
        let rawPostgresURL = ProcessInfo.processInfo.environment["ARIA_MCP_POSTGRES_URL"] ?? ""
        let rawSQLitePath = ProcessInfo.processInfo.environment["ARIA_MCP_SQLITE_PATH"] ?? ""

        let storage: any Storage

        if !rawPostgresURL.isEmpty && !rawSQLitePath.isEmpty {
            // Ambiguous config: both vars set. Never pick silently — the
            // operator must resolve the ambiguity by unsetting one of them.
            fputs(
                "ARIA_MCP fatal: ambiguous config — both ARIA_MCP_POSTGRES_URL and " +
                "ARIA_MCP_SQLITE_PATH are set. Unset one to select the intended backend.\n",
                stderr
            )
            exit(1)
        } else if !rawPostgresURL.isEmpty {
            // Only ARIA_MCP_POSTGRES_URL set → PostgreSQL-backed estate.
            // PostgreSQLStorage uses a lazy connection pool (no TCP connection
            // opened here). The pool defaults match PersistenceKit's
            // BackendConfiguration.postgresql defaults:
            //   poolSize: 10, connectionTimeout: 5.0s, idleTimeout: 300.0s
            // A connectivity failure surfaces at Estate.create/kit.open below.
            Logging.stderr.log(
                "ARIA_MCP starting (stdio, PostgreSQL backend: \(rawPostgresURL))"
            )
            let configuration = EstateConfiguration(
                estateID: UUID(),
                backend: .postgresql(connectionString: rawPostgresURL)
            )
            // PostgreSQLStorage.init is non-throwing (lazy pool); errors
            // surface at Estate.create / kit.open when the first connection
            // is attempted.
            storage = PostgreSQLStorage(configuration: configuration)
        } else if !rawSQLitePath.isEmpty {
            // Only ARIA_MCP_SQLITE_PATH set → SQLite-backed durable estate.
            let dbURL = URL(fileURLWithPath: rawSQLitePath)
            Logging.stderr.log("ARIA_MCP starting (stdio, SQLite backend: \(rawSQLitePath))")

            // Create parent directories so the caller does not need to
            // pre-create them. Bare filenames (no directory component) skip
            // creation entirely — exact parity with the Rust server's
            // empty-parent guard (server.rs from_env) — so a read-only cwd
            // does not fail a path that needs no directory created.
            if rawSQLitePath.contains("/") {
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
            // the PersistenceKit BackendConfiguration.sqlite default; sufficient
            // for a single-process server with no concurrent writers.
            let configuration = EstateConfiguration(
                estateID: UUID(),
                backend: .sqlite(url: dbURL, busyTimeout: 5.0)
            )
            do {
                storage = try SQLiteStorage(configuration: configuration)
            } catch {
                fputs(
                    "ARIA_MCP fatal: cannot open SQLite at '\(rawSQLitePath)': \(error)\n",
                    stderr
                )
                exit(1)
            }
        } else {
            // Neither set → in-memory ephemeral estate. The estate UUID is
            // fresh each run so the server serves one ephemeral estate per
            // process, matching the v1.0 owner-by-default credential model.
            Logging.stderr.log("ARIA_MCP starting (stdio, in-memory backend)")
            let configuration = EstateConfiguration(estateID: UUID(), backend: .inMemory)
            storage = InMemoryStorage(configuration: configuration)
        }

        let handle: EstateHandle
        do {
            // Estate.create opens the schema idempotently (DrawerStore uses
            // upsert for manifest keys), so calling it on an existing SQLite
            // or PostgreSQL estate is safe: it re-stamps owner_identifier and
            // leaves all other manifest values intact. The subsequent kit.open
            // validates the bitmap layout version and issues the EstateHandle.
            // For PostgreSQL, this is also the point where the lazy pool opens
            // its first real TCP connection — a connectivity failure surfaces
            // here as a thrown error.
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
