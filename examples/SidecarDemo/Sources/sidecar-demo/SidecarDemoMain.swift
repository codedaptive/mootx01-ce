import Foundation
import SidecarDemoApp
import AriaMCP

// MARK: - Agent-readable wiring notes
//
// This file is the headline demonstration of how an existing macOS
// application attaches a MOOT and opens it over the ARIA_MCP server.
//
// Read MootSidecar.swift first. This file is the driver around it.
// The pattern mirrors `apps/aria-mcp-server/Sources/aria-mcp/AriaMCPMain.swift`, with
// one substitution: instead of constructing the dispatcher inline, we
// ask `MootSidecar.attachInMemory()` for a ready-to-serve sidecar and
// pass its dispatcher to the stdio server.
//
// A real host app would call `MootSidecar.attach(storage:owner:)` with
// its own durable backend. The in-memory variant exists so the demo
// runs without touching the filesystem.

@main
struct SidecarDemoMain {
    static func main() async {
        // stdout is reserved for JSON-RPC frames (ARIA_MCP_SPEC_v0.2 §5).
        // All human-readable startup messages route to stderr through
        // AriaMCP's shared StderrLogger, the same one ARIA_MCP itself
        // uses.
        Logging.stderr.log(
            "SidecarDemo starting (in-memory MOOT, stdio MCP)"
        )

        let sidecar: MootSidecar
        do {
            sidecar = try await MootSidecar.attachInMemory()
        } catch {
            Logging.stderr.log(
                "SidecarDemo fatal: failed to attach MOOT: \(error)"
            )
            exit(1)
        }

        Logging.stderr.log(
            "SidecarDemo ready (\(sidecar.dispatcher.tools.count) tools)"
        )

        let server = StdioServer(dispatcher: sidecar.dispatcher)
        await server.run()

        Logging.stderr.log("SidecarDemo exiting (stdin closed)")
    }
}
