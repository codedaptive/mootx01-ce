import Foundation
import AriaMCP
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory

// Entry point for the ARIA_MCP stdio server.
//
// Opens a single GeniusLocusKit estate (an in-memory backend for the
// LAUNCH-04 transactional spike per LAUNCH_PLAN.md) and runs the
// JSON-RPC loop until stdin closes. Per ARIA_MCP_SPEC_v0.2 §5, stdout
// is reserved for JSON-RPC frames; any human-readable logging routes
// through Logging.stderr. The startup banner is therefore written to
// stderr only.
//
// Estate backend: in-memory for the launch spike. The mission scope
// is "wrap GeniusLocusKit and project AriaLexicon over MCP"; a
// persistent SQLite backend lights up at v1.0 once the installer
// landed in MISSION_LAUNCH_05 is wired through. The estate's UUID is
// fresh each run so the spike serves one ephemeral estate per
// process, matching the v1.0 "owner-by-default" credential model.

@main
struct AriaMCPMain {
    static func main() async {
        await AriaMCPMain.run()
    }

    static func run() async {
        Logging.stderr.log("ARIA_MCP starting (stdio, in-memory backend)")

        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-mcp-owner")
        let configuration = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: configuration)

        let handle: EstateHandle
        do {
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
