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

// MARK: - Transport stub (closure injection — the HTTP stub role)

/// Counting stub transport: plays the HTTP (or stdio) side, records every
/// frame sent, and replays canned responses in order. The invocation count
/// is the "stub server saw N requests" assertion.
private final class TransportStub: @unchecked Sendable {
    private(set) var sentFrames: [String] = []
    private var responses: [[String: Any]?]
    private let lock = NSLock()

    init(responses: [[String: Any]?]) {
        self.responses = responses
    }

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return sentFrames.count
    }

    func transport(kind: String = "http", endpoint: String? = "http://127.0.0.1:4242") -> BotLinkTransport {
        BotLinkTransport(kind: kind, endpoint: endpoint) { frame, _ in
            // withLock is the async-context-safe NSLock form (scoped, no
            // suspension inside the critical section).
            self.lock.withLock {
                self.sentFrames.append(frame)
                return self.responses.isEmpty ? nil : self.responses.removeFirst()
            }
        }
    }
}

/// A tools/call result payload with a single text content item.
private func textResult(_ text: String, isError: Bool = false) -> [String: Any] {
    [
        "content": [["type": "text", "text": text]],
        "isError": isError,
    ]
}

private func response(id: Any, result: [String: Any]) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id, "result": result]
}

/// Assert the outcome's stdout serializes as strict JSON and hand back the
/// re-parsed object for shape assertions. Every botLink stdout path must
/// survive this round-trip — the machine-JSON contract.
private func strictJSON(_ outcome: BotLinkOutcome) throws -> Any {
    let serialized = BotLink.serializeStdout(try #require(outcome.stdoutJSON))
    let data = try #require(serialized.data(using: .utf8))
    return try JSONSerialization.jsonObject(with: data)
}

// MARK: - Loopback guard (security boundary)

@Suite("BotLink — loopback guard")
struct BotLinkLoopbackGuardTests {

    @Test("the three loopback hosts pass, everything else is rejected")
    func loopbackAcceptance() {
        #expect(BotLink.validateLoopbackHTTP("http://127.0.0.1:4242") != nil)
        #expect(BotLink.validateLoopbackHTTP("http://localhost:9999") != nil)
        #expect(BotLink.validateLoopbackHTTP("http://[::1]:4242") != nil)
        // Non-loopback host: the spec's own example rejection.
        #expect(BotLink.validateLoopbackHTTP("http://example.com") == nil)
        // https is NOT loopback-http — copy of the proxy guard's strictness.
        #expect(BotLink.validateLoopbackHTTP("https://127.0.0.1:4242") == nil)
        #expect(BotLink.validateLoopbackHTTP("http://192.168.1.10:4242") == nil)
        #expect(BotLink.validateLoopbackHTTP("http://127.0.0.1.evil.com:4242") == nil)
        #expect(BotLink.validateLoopbackHTTP("not a url") == nil)
        #expect(BotLink.validateLoopbackHTTP("file:///etc/passwd") == nil)
    }

    @Test("a rejected --http URL means the transport is never invoked (zero requests)")
    func rejectedURLSendsNothing() async {
        // Mirrors the command layer's wiring: validation gates transport
        // construction, so a rejected URL never reaches send(). The stub's
        // request count is the "stub server saw zero requests" assertion.
        let stub = TransportStub(responses: [])
        if BotLink.validateLoopbackHTTP("http://example.com") != nil {
            _ = await BotLink.ping(transport: stub.transport())
        }
        #expect(stub.requestCount == 0)
    }
}

// MARK: - Argument parsing

@Suite("BotLink — argument parsing")
struct BotLinkArgumentTests {

    @Test("--args must be a JSON object; nested structures decode")
    func argsJSONStrictness() {
        let nested = BotLink.parseArgsJSON(#"{"query":"x","filter":{"kinds":["a","b"],"limit":3}}"#)
        #expect(nested?["query"] as? String == "x")
        let filter = nested?["filter"] as? [String: Any]
        #expect((filter?["kinds"] as? [String])?.count == 2)
        #expect(filter?["limit"] as? Int == 3)

        #expect(BotLink.parseArgsJSON(#"["not","an","object"]"#) == nil)
        #expect(BotLink.parseArgsJSON(#""scalar""#) == nil)
        #expect(BotLink.parseArgsJSON("{not json") == nil)
    }

    @Test("--key value pairs decode with the query parser semantics")
    func kvParserParity() {
        let parsed = BotLink.parseKVArguments(["--query", "x", "--limit", "3", "--exact", "true", "--flag"])
        #expect(parsed["query"] as? String == "x")
        #expect(parsed["limit"] as? Int == 3)
        #expect(parsed["exact"] as? Bool == true)
        #expect(parsed["flag"] as? Bool == true)
        // Bare -- separator and positionals are skipped, not misparsed.
        let skipped = BotLink.parseKVArguments(["--", "positional", "--k", "v"])
        #expect(skipped.count == 1)
        #expect(skipped["k"] as? String == "v")
    }

    @Test("--key pairs overlay the --args base (KV wins on collision)")
    func overlayPrecedence() {
        let base = BotLink.parseArgsJSON(#"{"query":"original","limit":5}"#)!
        let kv = BotLink.parseKVArguments(["--limit", "3", "--extra", "yes"])
        let merged = BotLink.overlayArguments(base: base, overlay: kv)
        #expect(merged["query"] as? String == "original", "base keys without overlay survive")
        #expect(merged["limit"] as? Int == 3, "the --key pair must win the collision")
        #expect(merged["extra"] as? String == "yes")
    }
}

// MARK: - Pong parsing

@Suite("BotLink — pong parsing")
struct BotLinkPongTests {

    @Test("the live daemon's pong line parses into estate/estateId/build")
    func livePongShape() {
        // Verbatim shape captured from the live daemon during mission recon.
        let parsed = BotLink.parsePong(
            "pong: estate  [797B75F6-9685-4050-90B7-8A10085CA456] is live — build 20260812180424/6bae5a30")
        #expect(parsed.estate == nil, "an empty estate name is omitted, not invented")
        #expect(parsed.estateId == "797B75F6-9685-4050-90B7-8A10085CA456")
        #expect(parsed.build == "20260812180424/6bae5a30")

        let named = BotLink.parsePong(
            "pong: estate work [ABC-123] is live — build 1/2")
        #expect(named.estate == "work")
        #expect(named.estateId == "ABC-123")
        #expect(named.build == "1/2")
    }

    @Test("a non-pong payload yields no fields (nothing invented)")
    func garbagePongOmitsAll() {
        let parsed = BotLink.parsePong("some unrelated text")
        #expect(parsed.estate == nil)
        #expect(parsed.estateId == nil)
        #expect(parsed.build == nil)
    }
}

// MARK: - Subcommand operations

@Suite("BotLink — ping")
struct BotLinkPingTests {

    @Test("ping shapes ok/transport/endpoint/estateId/build, exit 0, strict JSON")
    func pingSuccess() async throws {
        let stub = TransportStub(responses: [
            response(id: 2, result: textResult(
                "pong: estate  [797B75F6-9685-4050-90B7-8A10085CA456] is live — build 20260812180424/6bae5a30"))
        ])
        let outcome = await BotLink.ping(transport: stub.transport())
        #expect(outcome.exitCode == 0)
        let obj = try #require(try strictJSON(outcome) as? [String: Any])
        #expect(obj["ok"] as? Bool == true)
        #expect(obj["transport"] as? String == "http")
        #expect(obj["endpoint"] as? String == "http://127.0.0.1:4242")
        #expect(obj["estateId"] as? String == "797B75F6-9685-4050-90B7-8A10085CA456")
        #expect(obj["build"] as? String == "20260812180424/6bae5a30")
        #expect(obj["estate"] == nil, "empty estate name omitted")
        #expect(obj["toolCount"] == nil, "ping payload carries no toolCount — never invent")
        #expect(stub.requestCount == 1)
    }

    @Test("ping over stdio omits endpoint and attributes transport stdio")
    func pingStdioAttribution() async throws {
        let stub = TransportStub(responses: [
            response(id: 2, result: textResult("pong: estate w [X] is live — build b"))
        ])
        let outcome = await BotLink.ping(transport: stub.transport(kind: "stdio", endpoint: nil))
        #expect(outcome.exitCode == 0)
        let obj = try #require(try strictJSON(outcome) as? [String: Any])
        #expect(obj["transport"] as? String == "stdio")
        #expect(obj["endpoint"] == nil)
    }

    @Test("ping with isError:true exits 2 with the raw parseable result")
    func pingToolError() async throws {
        let stub = TransportStub(responses: [
            response(id: 2, result: textResult("estate unavailable", isError: true))
        ])
        let outcome = await BotLink.ping(transport: stub.transport())
        #expect(outcome.exitCode == 2)
        let obj = try #require(try strictJSON(outcome) as? [String: Any])
        #expect(obj["isError"] as? Bool == true)
    }

    @Test("a dead transport exits 1 with {ok:false,error} on stdout")
    func pingTransportFailure() async throws {
        struct Dead: Error {}
        let transport = BotLinkTransport(kind: "http", endpoint: "http://127.0.0.1:4242") { _, _ in
            throw Dead()
        }
        let outcome = await BotLink.ping(transport: transport)
        #expect(outcome.exitCode == 1)
        let obj = try #require(try strictJSON(outcome) as? [String: Any])
        #expect(obj["ok"] as? Bool == false)
        #expect(obj["error"] is String)
    }
}

@Suite("BotLink — list")
struct BotLinkListTests {

    @Test("list follows nextCursor and emits ONE combined tools array")
    func listCoalescesCursors() async throws {
        let stub = TransportStub(responses: [
            response(id: 2, result: [
                "tools": [["name": "moot_a", "description": "A", "inputSchema": ["type": "object"]]],
                "nextCursor": "page2",
            ]),
            response(id: 3, result: [
                "tools": [["name": "moot_b"]],
                "nextCursor": "page3",
            ]),
            response(id: 4, result: [
                "tools": [["name": "moot_c"]],
            ]),
        ])
        let outcome = await BotLink.list(transport: stub.transport())
        #expect(outcome.exitCode == 0)
        #expect(stub.requestCount == 3, "cursors are followed internally — the caller never loops")
        let obj = try #require(try strictJSON(outcome) as? [String: Any])
        let tools = try #require(obj["tools"] as? [[String: Any]])
        #expect(tools.map { $0["name"] as? String } == ["moot_a", "moot_b", "moot_c"])
    }

    @Test("single-page list emits the result object shape {tools:[…]}")
    func listSinglePage() async throws {
        let stub = TransportStub(responses: [
            response(id: 2, result: ["tools": [["name": "moot_estate_ping"]]])
        ])
        let outcome = await BotLink.list(transport: stub.transport())
        #expect(outcome.exitCode == 0)
        let obj = try #require(try strictJSON(outcome) as? [String: Any])
        #expect((obj["tools"] as? [[String: Any]])?.count == 1)
    }

    @Test("a transport failure mid-pagination exits 1")
    func listTransportFailure() async throws {
        let stub = TransportStub(responses: [
            response(id: 2, result: ["tools": [] as [[String: Any]], "nextCursor": "p2"])
            // Second page missing: stub returns nil → engine shapes exit 1.
        ])
        let outcome = await BotLink.list(transport: stub.transport())
        #expect(outcome.exitCode == 1)
        let obj = try #require(try strictJSON(outcome) as? [String: Any])
        #expect(obj["ok"] as? Bool == false)
    }
}

@Suite("BotLink — call")
struct BotLinkCallTests {

    @Test("call prepends moot_ and prints the raw result object, exit 0")
    func callSuccess() async throws {
        let stub = TransportStub(responses: [
            response(id: 2, result: textResult("found 3 memory(s)"))
        ])
        let outcome = await BotLink.call(
            verb: "memory_search",
            arguments: ["query": "x", "limit": 3],
            transport: stub.transport()
        )
        #expect(outcome.exitCode == 0)
        let sent = try #require(stub.sentFrames.first)
        #expect(sent.contains(#""name":"moot_memory_search""#) || sent.contains(#""moot_memory_search""#),
                "the verb gains the moot_ prefix exactly as query does")
        let obj = try #require(try strictJSON(outcome) as? [String: Any])
        #expect(obj["content"] is [Any], "stdout is the raw result object — not unwrapped")
        #expect(obj["isError"] as? Bool == false)
    }

    @Test("call with isError:true exits 2 and stdout stays parseable")
    func callToolErrorExit2() async throws {
        let stub = TransportStub(responses: [
            response(id: 2, result: textResult("no such tool", isError: true))
        ])
        let outcome = await BotLink.call(verb: "nope", arguments: [:], transport: stub.transport())
        #expect(outcome.exitCode == 2)
        let obj = try #require(try strictJSON(outcome) as? [String: Any])
        #expect(obj["isError"] as? Bool == true)
    }

    @Test("a JSON-RPC error member exits 1 with shaped stdout")
    func callProtocolErrorExit1() async throws {
        let stub = TransportStub(responses: [
            ["jsonrpc": "2.0", "id": 2, "error": ["code": -32601, "message": "method not found"]]
        ])
        let outcome = await BotLink.call(verb: "x", arguments: [:], transport: stub.transport())
        #expect(outcome.exitCode == 1)
        let obj = try #require(try strictJSON(outcome) as? [String: Any])
        #expect(obj["ok"] as? Bool == false)
    }
}

@Suite("BotLink — rpc")
struct BotLinkRpcTests {

    @Test("an id-bearing frame is forwarded verbatim and the response frame comes back whole")
    func rpcFrameRoundTrip() async throws {
        let stub = TransportStub(responses: [
            response(id: 9, result: textResult("ok"))
        ])
        let frame = #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"moot_estate_ping","arguments":{}}}"#
        let outcome = await BotLink.rpc(frame: frame, transport: stub.transport())
        #expect(outcome.exitCode == 0)
        #expect(stub.sentFrames.first == frame, "caller bytes are forwarded verbatim, never re-encoded")
        let obj = try #require(try strictJSON(outcome) as? [String: Any])
        #expect(obj["jsonrpc"] as? String == "2.0", "stdout is the whole response FRAME, not the unwrapped result")
    }

    @Test("a notification frame yields empty stdout and exit 0")
    func rpcNotification() async {
        let stub = TransportStub(responses: [nil])
        let frame = #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{}}"#
        let outcome = await BotLink.rpc(frame: frame, transport: stub.transport())
        #expect(outcome.exitCode == 0)
        #expect(outcome.stdoutJSON == nil, "a notification produces NO stdout")
    }

    @Test("a malformed frame is usage error: exit 64, nothing sent")
    func rpcMalformedFrame() async throws {
        let stub = TransportStub(responses: [])
        let outcome = await BotLink.rpc(frame: "{not json", transport: stub.transport())
        #expect(outcome.exitCode == 64)
        #expect(stub.requestCount == 0, "a frame that does not parse is never forwarded")
        let obj = try #require(try strictJSON(outcome) as? [String: Any])
        #expect(obj["ok"] as? Bool == false)
    }

    @Test("a response with a JSON-RPC error member exits 1, frame still on stdout")
    func rpcErrorMember() async throws {
        let stub = TransportStub(responses: [
            ["jsonrpc": "2.0", "id": 4, "error": ["code": -32600, "message": "invalid"]]
        ])
        let frame = #"{"jsonrpc":"2.0","id":4,"method":"bogus"}"#
        let outcome = await BotLink.rpc(frame: frame, transport: stub.transport())
        #expect(outcome.exitCode == 1)
        let obj = try #require(try strictJSON(outcome) as? [String: Any])
        #expect(obj["error"] is [String: Any], "the error frame itself is the stdout value")
    }

    @Test("a result carrying isError:true exits 2 through rpc as well")
    func rpcIsErrorExit2() async {
        let stub = TransportStub(responses: [
            response(id: 5, result: textResult("failed", isError: true))
        ])
        let frame = #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"moot_x","arguments":{}}}"#
        let outcome = await BotLink.rpc(frame: frame, transport: stub.transport())
        #expect(outcome.exitCode == 2)
    }
}
