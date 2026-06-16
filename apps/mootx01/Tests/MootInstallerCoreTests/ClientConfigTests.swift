// ClientConfigTests.swift
//
// Verifies the shape of the MCP server entry the bash installer
// merges into client config files, and the localConfigPath values
// that drive --local mode. The Python merge in install.sh reads the
// JSON this code emits; if the shape drifts, the merge breaks silently.

import XCTest
@testable import MootInstallerCore

final class ClientConfigTests: XCTestCase {

    func testSupportedClientsCoverLaunchPlanClients() {
        let ids = MCPClients.supported.map { $0.id }
        XCTAssertTrue(ids.contains("claude-desktop"))
        XCTAssertTrue(ids.contains("claude-code"))
        XCTAssertTrue(ids.contains("cursor"))
        XCTAssertTrue(ids.contains("cline"))
        XCTAssertTrue(ids.contains("continue"))
    }

    func testAllClientsShareTheSameServerName() {
        for client in MCPClients.supported {
            XCTAssertEqual(client.serverName, MCPClients.serverName)
        }
    }

    func testEntryUsesAbsoluteBinaryPath() {
        let entry = MCPServerEntryBuilder.entry(
            binaryPath: "/Users/test/.mootx01/bin/mootx01"
        )
        XCTAssertEqual(entry.command, "/Users/test/.mootx01/bin/mootx01")
        XCTAssertTrue(entry.args.isEmpty)
        XCTAssertTrue(entry.env.isEmpty)
    }

    func testEntryJSONIsStableSortedKeys() throws {
        let json = try MCPServerEntryBuilder.entryJSON(
            binaryPath: "/abs/path/mootx01"
        )
        // Sorted-keys formatting is what makes the Python merge in
        // install.sh produce stable diffs across runs. If JSONEncoder
        // ever loses the option the diff churn returns; lock it in.
        XCTAssertEqual(
            json,
            "{\"args\":[],\"command\":\"/abs/path/mootx01\",\"env\":{}}"
        )
    }

    // MARK: - localConfigPath (--local mode)

    func testOnlyClaudeCodeHasNonNilLocalConfigPath() {
        // Only Claude Code supports project-local scoping (.mcp.json).
        // All other clients are global-only; their localConfigPath must
        // be nil so install.sh --local leaves them on their global paths.
        for client in MCPClients.supported where client.id != "claude-code" {
            XCTAssertNil(
                client.localConfigPath,
                "\(client.displayName) (\(client.id)) should have nil localConfigPath — only Claude Code supports project-local scoping"
            )
        }
    }

    func testClaudeCodeLocalConfigPathIsDotMCPJson() {
        guard let client = MCPClients.supported.first(where: { $0.id == "claude-code" }) else {
            XCTFail("claude-code not found in MCPClients.supported")
            return
        }
        // Claude Code reads .mcp.json from the project root for project-local
        // servers. The installer writes this file when --local is passed.
        XCTAssertEqual(client.localConfigPath, ".mcp.json")
    }
}
