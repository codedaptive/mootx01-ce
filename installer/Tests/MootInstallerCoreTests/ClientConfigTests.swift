// ClientConfigTests.swift
//
// Verifies the shape of the MCP server entry the bash installer
// merges into client config files. The Python merge in install.sh
// reads the JSON this code emits; if the shape drifts, the merge
// breaks silently.

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
            binaryPath: "/Users/test/.local/share/MOOTx01/bin/mootx01-mcp"
        )
        XCTAssertEqual(entry.command, "/Users/test/.local/share/MOOTx01/bin/mootx01-mcp")
        XCTAssertTrue(entry.args.isEmpty)
        XCTAssertTrue(entry.env.isEmpty)
    }

    func testEntryJSONIsStableSortedKeys() throws {
        let json = try MCPServerEntryBuilder.entryJSON(
            binaryPath: "/abs/path/mootx01-mcp"
        )
        // Sorted-keys formatting is what makes the Python merge in
        // install.sh produce stable diffs across runs. If JSONEncoder
        // ever loses the option the diff churn returns; lock it in.
        XCTAssertEqual(
            json,
            "{\"args\":[],\"command\":\"/abs/path/mootx01-mcp\",\"env\":{}}"
        )
    }
}
