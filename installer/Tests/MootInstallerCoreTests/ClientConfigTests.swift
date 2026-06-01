// ClientConfigTests.swift
//
// Verifies the shape of the MCP server entry the bash installer
// merges into client config files. The Python merge in install.sh
// reads the JSON this code emits; if the shape drifts, the merge
// breaks silently.

import Testing
@testable import MootInstallerCore

@Suite("MCP client config shape")
struct ClientConfigTests {

    @Test("supported clients cover the launch-plan clients")
    func supportedClientsCoverLaunchPlanClients() {
        let ids = MCPClients.supported.map { $0.id }
        #expect(ids.contains("claude-desktop"))
        #expect(ids.contains("claude-code"))
        #expect(ids.contains("cursor"))
        #expect(ids.contains("cline"))
        #expect(ids.contains("continue"))
    }

    @Test("all clients share the same server name")
    func allClientsShareTheSameServerName() {
        for client in MCPClients.supported {
            #expect(client.serverName == MCPClients.serverName)
        }
    }

    @Test("entry uses the absolute binary path")
    func entryUsesAbsoluteBinaryPath() {
        let entry = MCPServerEntryBuilder.entry(
            binaryPath: "/Users/test/.local/share/MOOTx01/bin/mootx01-mcp"
        )
        #expect(entry.command == "/Users/test/.local/share/MOOTx01/bin/mootx01-mcp")
        #expect(entry.args.isEmpty)
        #expect(entry.env.isEmpty)
    }

    @Test("entry JSON is stable with sorted keys")
    func entryJSONIsStableSortedKeys() throws {
        let json = try MCPServerEntryBuilder.entryJSON(
            binaryPath: "/abs/path/mootx01-mcp"
        )
        // Sorted-keys formatting is what makes the Python merge in
        // install.sh produce stable diffs across runs. If JSONEncoder
        // ever loses the option the diff churn returns; lock it in.
        #expect(
            json == "{\"args\":[],\"command\":\"/abs/path/mootx01-mcp\",\"env\":{}}"
        )
    }
}
