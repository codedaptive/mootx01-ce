// ClientConfigTests.swift
//
// Verifies the shape of the legacy MCPServerEntryBuilder stdio entry
// and the localConfigPath values that drive --local mode. The Swift
// installer (Installer.swift) writes client config directly; these
// tests exercise MCPServerEntryBuilder, which is no longer used by
// production install paths and is referenced only by this test suite.

import Foundation
import Testing
@testable import MootInstallerCore

@Suite("Client config & MCP server entries")
struct ClientConfigTests {

    @Test func supportedClientsCoverLaunchPlanClients() {
        let ids = MCPClients.supported.map { $0.id }
        #expect(ids.contains("claude-desktop"))
        #expect(ids.contains("claude-code"))
        #expect(ids.contains("cursor"))
        #expect(ids.contains("cline"))
        #expect(ids.contains("continue"))
    }

    @Test func allClientsShareTheSameServerName() {
        for client in MCPClients.supported {
            #expect(client.serverName == MCPClients.serverName)
        }
    }

    @Test func entryUsesAbsoluteBinaryPath() {
        let entry = MCPServerEntryBuilder.entry(
            binaryPath: "/Users/test/.mootx01/bin/mootx01"
        )
        #expect(entry.command == "/Users/test/.mootx01/bin/mootx01")
        #expect(entry.args.isEmpty)
        #expect(entry.env.isEmpty)
    }

    @Test func entryJSONIsStableSortedKeys() throws {
        let json = try MCPServerEntryBuilder.entryJSON(
            binaryPath: "/abs/path/mootx01"
        )
        // Sorted-keys formatting produces stable JSON output across runs.
        // If JSONEncoder ever loses the sortedKeys option the key order
        // becomes insertion-order and diff churn returns; lock it in.
        #expect(
            json ==
            "{\"args\":[],\"command\":\"/abs/path/mootx01\",\"env\":{}}"
        )
    }

    // MARK: - localConfigPath (--local mode)

    @Test func onlyClaudeCodeHasNonNilLocalConfigPath() {
        // Only Claude Code supports project-local scoping (.mcp.json).
        // All other clients are global-only; their localConfigPath must
        // be nil so `mootx01 install --location local` leaves them on
        // their global config paths.
        for client in MCPClients.supported where client.id != "claude-code" {
            #expect(
                client.localConfigPath == nil,
                "\(client.displayName) (\(client.id)) should have nil localConfigPath — only Claude Code supports project-local scoping"
            )
        }
    }

    @Test func claudeCodeLocalConfigPathIsDotMCPJson() throws {
        let client = try #require(
            MCPClients.supported.first(where: { $0.id == "claude-code" }),
            "claude-code not found in MCPClients.supported"
        )
        // Claude Code reads .mcp.json from the project root for project-local
        // servers. The installer writes this file when --local is passed.
        #expect(client.localConfigPath == ".mcp.json")
    }
}
