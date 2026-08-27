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

    // MARK: - BL-01 regressions (Codex #42, #41, #47)

    @Test("the control plane is unreachable: a non-root --http path is refused")
    func controlPlanePathRefused() {
        // Codex #42. The daemon serves POST /api/control/unlock on the same
        // loopback listener as the JSON-RPC endpoint, and that route grants a
        // sensitivity tier on a fresh timestamp alone (authenticating the user
        // is the CLI's job). A guard that checked only scheme and host let
        //   botlink rpc --http http://127.0.0.1:4242/api/control/unlock
        // POST a caller-authored body straight to it, silently granting the
        // secret tier and bypassing `mootx01 unlock`'s LocalAuthentication.
        // Pre-fix these all returned non-nil.
        #expect(BotLink.validateLoopbackHTTP("http://127.0.0.1:4242/api/control/unlock") == nil)
        #expect(BotLink.validateLoopbackHTTP("http://127.0.0.1:4242/api/control/lock") == nil)
        #expect(BotLink.validateLoopbackHTTP("http://localhost:4242/api/graph") == nil)
        // Traversal and encoded spellings resolve to a non-root path too.
        #expect(BotLink.validateLoopbackHTTP("http://127.0.0.1:4242/../api/control/unlock") == nil)
        // A query or fragment is refused for the same reason: neither has a
        // legitimate use on the JSON-RPC endpoint, and `url.path` alone does
        // not capture them.
        #expect(BotLink.validateLoopbackHTTP("http://127.0.0.1:4242/?x=1") == nil)
        #expect(BotLink.validateLoopbackHTTP("http://127.0.0.1:4242/#frag") == nil)
    }

    @Test("the legitimate root-path flow still works (both spellings)")
    func rootPathStillAccepted() {
        // The fix must not cost botLink its actual job. Bare authority and a
        // lone trailing slash are the two spellings of the JSON-RPC endpoint.
        #expect(BotLink.validateLoopbackHTTP("http://127.0.0.1:4242") != nil)
        #expect(BotLink.validateLoopbackHTTP("http://127.0.0.1:4242/") != nil)
        #expect(BotLink.validateLoopbackHTTP("http://localhost/") != nil)
        #expect(BotLink.validateLoopbackHTTP("http://[::1]:4242/") != nil)
    }

    @Test("an out-of-range port is a clean rejection, not a crash")
    func portRangeRefused() {
        // Codex #41. URL(string:) does not range-check the port: it parses
        // ":99999" and reports port == 99999, which reached daemonAlive's
        // `UInt16(port)` narrowing and TRAPPED ("Not enough bits to represent
        // the passed value", exit 133). Pre-fix these returned non-nil.
        #expect(BotLink.validateLoopbackHTTP("http://127.0.0.1:0") == nil)
        #expect(BotLink.validateLoopbackHTTP("http://127.0.0.1:65536") == nil)
        #expect(BotLink.validateLoopbackHTTP("http://127.0.0.1:99999") == nil)
        #expect(BotLink.validateLoopbackHTTP("http://[::1]:70000") == nil)
        // A negative port never reached the trap — URL(string:) returns nil
        // for it — but it must stay rejected.
        #expect(BotLink.validateLoopbackHTTP("http://127.0.0.1:-1") == nil)
        // The boundary values themselves are legal ports.
        #expect(BotLink.validateLoopbackHTTP("http://127.0.0.1:1") != nil)
        #expect(BotLink.validateLoopbackHTTP("http://127.0.0.1:65535") != nil)
    }

    @Test("daemonAlive refuses an out-of-range port instead of trapping")
    func daemonAliveGuardsNarrowing() {
        // Defense in depth for the same narrowing: this path is also reached
        // with the RESOLVED default port, which never passes through
        // validateLoopbackHTTP, so a corrupt port file could otherwise trap
        // here. Pre-fix these calls crashed the process rather than returning.
        #expect(McpLoopback.daemonAlive(port: 99999) == false)
        #expect(McpLoopback.daemonAlive(port: 65536) == false)
        #expect(McpLoopback.daemonAlive(port: 0) == false)
        #expect(McpLoopback.daemonAlive(port: -1) == false)
    }

    @Test("an oversized stdin frame is refused, not truncated")
    func stdinFrameBounded() throws {
        // Codex #47. An unbounded read lets a large or never-terminating
        // producer exhaust local memory. A small limit is used here so the
        // test stays fast; the production cap is BotLink.maxStdinFrameBytes.
        let limit = 1024

        // Over the cap: refused outright. Returning nil rather than a
        // truncated prefix is the point — a silently truncated frame would
        // reach the parser as malformed JSON and misreport the cause.
        let overPipe = Pipe()
        try overPipe.fileHandleForWriting.write(
            contentsOf: Data(repeating: UInt8(ascii: "a"), count: limit + 1))
        try overPipe.fileHandleForWriting.close()
        #expect(try BotLink.readBoundedFrame(
            from: overPipe.fileHandleForReading, limit: limit) == nil)

        // Exactly at the cap: accepted, whole, unmodified.
        let atPipe = Pipe()
        try atPipe.fileHandleForWriting.write(
            contentsOf: Data(repeating: UInt8(ascii: "b"), count: limit))
        try atPipe.fileHandleForWriting.close()
        let atFrame = try BotLink.readBoundedFrame(
            from: atPipe.fileHandleForReading, limit: limit)
        #expect(atFrame?.count == limit)

        // A normal frame round-trips and is trimmed, exactly as the old
        // readDataToEndOfFile path did.
        let okPipe = Pipe()
        try okPipe.fileHandleForWriting.write(contentsOf: Data("  {\"id\":1}\n".utf8))
        try okPipe.fileHandleForWriting.close()
        #expect(try BotLink.readBoundedFrame(
            from: okPipe.fileHandleForReading, limit: limit) == "{\"id\":1}")
    }

    @Test("the production stdin cap matches the daemon's own body limit")
    func stdinCapMatchesDaemonBodyLimit() {
        // Derived, not invented: HTTPServer.maxBodyBytes defaults to 4 MiB on
        // both verticals, so a larger frame is refused by the receiving end
        // regardless. If that default moves, this cap should move with it.
        #expect(BotLink.maxStdinFrameBytes == 4 * 1024 * 1024)
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

    @Test("advisory lines never leak into build — parse is head-line-only (G-1)")
    func multiLinePongAdvisoriesDoNotLeakIntoBuild() {
        // runEstatePing appends up to two OPT-IN-AND-LIVE advisory lines to
        // the same text payload (ToolDispatch: version_skew on skew,
        // update_available on the first ping of every TTL window). A parser
        // that scans the whole text swallows them into `build` while every
        // exit-0/strict-JSON gate stays green — exact equality is the only
        // assertion that catches it.
        let parsed = BotLink.parsePong("""
        pong: estate work [ABC-123] is live — build 20260812180424/6bae5a30
        version_skew: server 1.1.4 vs client 1.1.2
        update_available: 1.1.5
        """)
        #expect(parsed.build == "20260812180424/6bae5a30")
        #expect(parsed.estate == "work")
        #expect(parsed.estateId == "ABC-123")
        #expect(parsed.advisories == [
            "version_skew: server 1.1.4 vs client 1.1.2",
            "update_available: 1.1.5",
        ], "advisory lines are surfaced separately (ping forwards them to stderr), never inside a field")
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
        // The quiesced/unmounted estate paths return errorResult — real
        // runtime states. Exit 2 (not 0, not 1) is the load-bearing
        // distinction from a dead hop; stdout is the raw result, and it is
        // NOT the synthesized ok:true shape.
        let stub = TransportStub(responses: [
            response(id: 2, result: textResult("estate quiesced — draining", isError: true))
        ])
        let outcome = await BotLink.ping(transport: stub.transport())
        #expect(outcome.exitCode == 2)
        let obj = try #require(try strictJSON(outcome) as? [String: Any])
        #expect(obj["isError"] as? Bool == true)
        #expect(obj["ok"] == nil, "the isError path must never emit the ok:true liveness shape")
    }

    @Test("ping with the three-line production payload keeps build exact (G-1)")
    func pingMultiLinePayloadBuildExact() async throws {
        let stub = TransportStub(responses: [
            response(id: 2, result: textResult("""
            pong: estate work [ABC-123] is live — build 20260812180424/6bae5a30
            version_skew: server 1.1.4 vs client 1.1.2
            update_available: 1.1.5
            """))
        ])
        let outcome = await BotLink.ping(transport: stub.transport())
        #expect(outcome.exitCode == 0)
        let obj = try #require(try strictJSON(outcome) as? [String: Any])
        #expect(obj["build"] as? String == "20260812180424/6bae5a30",
                "exact equality — advisories must not be swallowed into build")
        #expect(obj["estate"] as? String == "work")
        #expect(obj["estateId"] as? String == "ABC-123")
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
            response(id: 2, result: textResult("found 3 candidate memories, one per line"))
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

// MARK: - Exec tests through the symlink (gate B-1(b))

/// Anchor class for locating the built products directory from the test
/// bundle (Swift Testing has no test class; Bundle(for:) needs one).
private final class BotLinkExecBundleFinder {}

/// Minimal in-process loopback HTTP stub: accepts connections on an
/// ephemeral 127.0.0.1 port, answers every HTTP POST with the canned
/// JSON-RPC response, and counts POSTs. Probe connections (connect +
/// close, no bytes) are served and NOT counted — only parsed HTTP
/// requests count, so `postCount == 0` genuinely means "the stub server
/// saw zero requests".
private final class LoopbackHTTPStub: @unchecked Sendable {
    private let serverSocket: Int32
    let port: Int
    private let responseBody: String
    private let lock = NSLock()
    private var posts = 0

    var postCount: Int {
        lock.withLock { posts }
    }

    init(responseBody: String) throws {
        self.responseBody = responseBody
        // Locals throughout — the withUnsafePointer closures must not
        // capture self before all stored properties are initialized.
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        precondition(sock >= 0, "socket() failed")
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // ephemeral
        addr.sin_addr.s_addr = 0x0100007F // 127.0.0.1 (host little-endian)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        precondition(bindResult == 0, "bind() failed")
        listen(sock, 8)

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(sock, $0, &len)
            }
        }
        serverSocket = sock
        port = Int(UInt16(bigEndian: bound.sin_port))

        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "bl1-http-stub"
        thread.start()
    }

    func stop() {
        close(serverSocket)
    }

    private func acceptLoop() {
        while true {
            let client = accept(serverSocket, nil, nil)
            guard client >= 0 else { return } // server socket closed → done
            // 5 s receive timeout so a wedged peer cannot hang the test run.
            var tv = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            handle(client: client)
            close(client)
        }
    }

    private func handle(client: Int32) {
        var request = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        // Read until the header terminator, then drain the declared body.
        while !request.contains5CRLFCRLF() {
            let n = recv(client, &buf, buf.count, 0)
            if n <= 0 { return } // probe connection or peer error: not a POST
            request.append(contentsOf: buf[0..<n])
        }
        let headerText = String(decoding: request, as: UTF8.self)
        var bodyExpected = 0
        for line in headerText.split(separator: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                bodyExpected = Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        if let headerEnd = headerText.range(of: "\r\n\r\n") {
            var bodyGot = headerText[headerEnd.upperBound...].utf8.count
            while bodyGot < bodyExpected {
                let n = recv(client, &buf, buf.count, 0)
                if n <= 0 { break }
                bodyGot += n
            }
        }
        lock.withLock { posts += 1 }
        let body = Data(responseBody.utf8)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        out.withUnsafeBytes { raw in
            _ = send(client, raw.baseAddress, raw.count, 0)
        }
    }
}

private extension Data {
    /// True when the buffer contains the HTTP header terminator CRLFCRLF.
    func contains5CRLFCRLF() -> Bool {
        guard count >= 4 else { return false }
        let terminator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        return firstRange(of: Data(terminator)) != nil
    }
}

@Suite("BotLink — exec through the mootx01-botLink symlink", .serialized)
struct BotLinkExecTests {

    /// The built `mootx01` binary, sitting beside the test bundle in the
    /// products directory (SPM builds executable targets for test runs).
    private func builtBinaryURL() throws -> URL {
        let url = Bundle(for: BotLinkExecBundleFinder.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("mootx01", isDirectory: false)
        try #require(FileManager.default.isExecutableFile(atPath: url.path),
                     "built mootx01 binary not found at \(url.path)")
        return url
    }

    /// Symlink the built binary as `mootx01-botLink` in a temp dir and
    /// return the symlink URL.
    private func makeSymlink() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bl1-exec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent(ArgvDispatch.botLinkInvocationName, isDirectory: false)
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: try builtBinaryURL().path)
        return link
    }

    private func exec(_ executable: URL, _ args: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        // Empty stdin so the exec'd process never inherits or waits on the
        // test runner's stdin.
        process.standardInput = Pipe()
        try process.run()
        let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
        let stderrData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: stdoutData, as: UTF8.self),
                String(decoding: stderrData, as: UTF8.self))
    }

    @Test("execing <tmp>/mootx01-botLink ping against a stub daemon exits 0 with strict-JSON stdout")
    func execPingThroughSymlink() throws {
        // If ArgumentParser stops accepting the injected array, or
        // BotLinkCommand falls out of either subcommand list, THIS test
        // fails while every pure-array unit test stays green.
        let stub = try LoopbackHTTPStub(responseBody:
            #"{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"pong: estate work [ABC-123] is live — build 1/2"}],"isError":false}}"#)
        defer { stub.stop() }
        let link = try makeSymlink()
        defer { try? FileManager.default.removeItem(at: link.deletingLastPathComponent()) }

        let result = try exec(link, ["ping", "--http", "http://127.0.0.1:\(stub.port)"])
        #expect(result.status == 0)
        let data = Data(result.stdout.utf8)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any],
                               "stdout must be one strict-JSON value, got: \(result.stdout)")
        #expect(obj["ok"] as? Bool == true)
        #expect(obj["transport"] as? String == "http")
        #expect(obj["estateId"] as? String == "ABC-123")
        #expect(stub.postCount == 1, "exactly one POST for a one-shot ping")
    }

    @Test("execing the symlink with a non-loopback --http exits 64 and the stub sees ZERO requests")
    func execNonLoopbackExits64WithZeroRequests() throws {
        let stub = try LoopbackHTTPStub(responseBody: "{}")
        defer { stub.stop() }
        let link = try makeSymlink()
        defer { try? FileManager.default.removeItem(at: link.deletingLastPathComponent()) }

        let result = try exec(link, ["ping", "--http", "http://example.com"])
        #expect(result.status == 64)
        let obj = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        #expect(obj?["ok"] as? Bool == false)
        #expect(stub.postCount == 0, "a rejected URL must never produce a request — fails CLOSED")
    }
}
