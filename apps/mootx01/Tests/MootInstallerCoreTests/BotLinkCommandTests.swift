// BotLinkCommandTests.swift
//
// BL-1: tests for the botLink one-shot MCP transport engine.
//
// The testable engine lives in MootInstallerCore (BotLink.swift +
// McpOneShot.swift) per this app's established split: MootInstallerCore
// holds testable logic; the `mootx01` executable target is a thin CLI
// wrapper that tests cannot import. `BotLinkCommand.swift` (executable
// target) wires real transports around the engine tested here.
//
// Transport stubbing is closure injection (the ReleaseDownloader mockFetch
// precedent) — no live HTTP server. The subprocess path is stubbed with a
// fake `serve` shell script that speaks canned newline-delimited JSON-RPC.

import Foundation
import Testing

@testable import MootInstallerCore

// MARK: - Subprocess stub helpers

/// Write an executable shell script that plays the `mootx01 serve` role:
/// reads newline-delimited JSON-RPC frames from stdin and answers with the
/// canned response lines wired per method substring. Exits on stdin EOF,
/// exactly like the real serve loop.
private func makeFakeServe(_ caseLines: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("bl1-fake-serve-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let script = dir.appendingPathComponent("fake-serve.sh", isDirectory: false)
    let body = """
    #!/bin/sh
    while read line; do
      case "$line" in
    \(caseLines)
      esac
    done
    """
    try body.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
}

private func cleanupFakeServe(_ script: URL) {
    try? FileManager.default.removeItem(at: script.deletingLastPathComponent())
}

// MARK: - McpOneShot (generalized subprocess path, Part 2)

@Suite("McpOneShot — generalized subprocess JSON-RPC")
struct McpOneShotTests {

    @Test("tools/list drives the subprocess path against a stub serve")
    func toolsListThroughSubprocessStub() async throws {
        // tools/list case first: the `initialized` notification contains the
        // substring "initialize", so the initialize arm must come after any
        // more-specific match and double-firing on it is harmless (the reader
        // matches by response id, not by line count).
        let script = try makeFakeServe("""
            *tools/list*) echo '{"jsonrpc":"2.0","id":7,"result":{"tools":[{"name":"moot_estate_ping","description":"liveness"}]}}' ;;
            *initialize*) echo '{"jsonrpc":"2.0","id":1,"result":{}}' ;;
        """)
        defer { cleanupFakeServe(script) }

        let frame = McpOneShot.encodeFrame(id: 7, method: "tools/list", params: [:])
        let response = try await McpOneShot.subprocessCall(
            binaryPath: script.path,
            serveArgs: ["serve"],
            frame: frame,
            expectID: 7,
            clientName: "bl1-test"
        )
        let result = try #require(response?["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools.first?["name"] as? String == "moot_estate_ping")
    }

    @Test("a notification frame (nil expectID) returns nil and does not wait for a response")
    func notificationFrameReturnsNil() async throws {
        let script = try makeFakeServe("""
            *initialize*) echo '{"jsonrpc":"2.0","id":1,"result":{}}' ;;
        """)
        defer { cleanupFakeServe(script) }

        let frame = McpOneShot.encodeFrame(
            id: nil, method: "notifications/cancelled", params: [:])
        let response = try await McpOneShot.subprocessCall(
            binaryPath: script.path,
            serveArgs: ["serve"],
            frame: frame,
            expectID: nil,
            clientName: "bl1-test"
        )
        #expect(response == nil, "a notification has no response frame")
    }

    @Test("no matching response id throws noResponse")
    func missingResponseThrows() async throws {
        let script = try makeFakeServe("""
            *initialize*) echo '{"jsonrpc":"2.0","id":1,"result":{}}' ;;
        """)
        defer { cleanupFakeServe(script) }

        let frame = McpOneShot.encodeFrame(id: 9, method: "tools/call", params: ["name": "moot_x"])
        await #expect(throws: McpOneShotError.self) {
            _ = try await McpOneShot.subprocessCall(
                binaryPath: script.path,
                serveArgs: ["serve"],
                frame: frame,
                expectID: 9,
                clientName: "bl1-test"
            )
        }
    }

    @Test("string response ids match string expectIDs (rpc escape-hatch parity)")
    func stringIDMatch() async throws {
        let script = try makeFakeServe("""
            *tools/call*) echo '{"jsonrpc":"2.0","id":"abc","result":{"content":[],"isError":false}}' ;;
            *initialize*) echo '{"jsonrpc":"2.0","id":1,"result":{}}' ;;
        """)
        defer { cleanupFakeServe(script) }

        let frame = #"{"jsonrpc":"2.0","id":"abc","method":"tools/call","params":{"name":"moot_estate_ping","arguments":{}}}"#
        let response = try await McpOneShot.subprocessCall(
            binaryPath: script.path,
            serveArgs: ["serve"],
            frame: frame,
            expectID: "abc",
            clientName: "bl1-test"
        )
        #expect(response?["result"] is [String: Any])
    }
}
