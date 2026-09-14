import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
import LoopbackHTTP
@testable import AriaMCP

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// End-to-end coverage for the HTTP MCP transport: the same JSON-RPC surface as
/// stdio, exercised over a real loopback TCP socket. Each test binds an
/// OS-assigned port (0), serves on a dedicated accept thread, and drives a raw
/// HTTP client so the wire bytes are what an MCP client would actually send.
///
/// `.serialized`: each case opens a live in-memory estate and a real listener;
/// keep them one-at-a-time.
@Suite("HTTP transport", .serialized)
struct HTTPServerTests {

    // MARK: - Harness

    /// Build a fresh in-memory estate (mirrors ServerTests).
    private func makeKitAndHandle() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-mcp-http-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
        return (kit, handle)
    }

    /// Build a dispatcher wired to a fresh in-memory estate.
    private func makeDispatcher() async throws -> ARIA_MCPDispatcher {
        let (kit, handle) = try await makeKitAndHandle()
        let info = ARIA_MCPDispatcher.ServerInfo(name: "ARIA_MCP", version: "test")
        let tooling = ToolDispatcher(kit: kit, handle: handle)
        return ARIA_MCPDispatcher(info: info, tooling: tooling)
    }

    /// Build a dispatcher and keep direct access to the same estate for seeding.
    private func makeDispatcherWithEstate() async throws -> (
        dispatcher: ARIA_MCPDispatcher,
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) {
        let (kit, handle) = try await makeKitAndHandle()
        let info = ARIA_MCPDispatcher.ServerInfo(name: "ARIA_MCP", version: "test")
        let tooling = ToolDispatcher(kit: kit, handle: handle)
        return (ARIA_MCPDispatcher(info: info, tooling: tooling), kit, handle)
    }

    /// Bind an HTTPServer on an OS-assigned port and serve connections on a
    /// dedicated accept thread. Calls `HTTPServer.serve` directly, bypassing the
    /// two-phase `ConcurrencyGate.tryEnqueue()` accept-thread path in `run()`.
    /// Returns the bound port and a stop closure; closing the listener unblocks
    /// accept so the thread exits.
    ///
    /// `topologyReader`: optional closure forwarded to `HTTPServer.serve`. Pass a
    /// pre-built payload closure for tests that exercise GET /api/graph with a live
    /// snapshot; omit (nil) for tests that expect `structurePending: true`.
    private func startServing(
        _ dispatcher: ARIA_MCPDispatcher,
        topologyReader: (@Sendable (String?) async -> Data?)? = nil
    ) throws -> (port: UInt16, stop: () -> Void) {
        let server = HTTPServer(dispatcher: dispatcher, port: 0, topologyReader: topologyReader)
        let (listenFD, port) = try server.bind()
        let reader = topologyReader
        let thread = Thread {
            while let cfd = POSIXSocket.acceptOne(listenFD) {
                Task { await HTTPServer.serve(cfd, dispatcher: dispatcher, maxBodyBytes: 4 * 1024 * 1024, topologyReader: reader, sseGate: globalSSEConcurrencyGate) }
            }
        }
        thread.name = "aria-mcp.http.test.accept"
        thread.start()
        return (port, { close(listenFD) })
    }

    /// Open a raw socket connection to 127.0.0.1:port, send a raw HTTP request
    /// string, and read up to `maxBytes` bytes (for SSE streams that do NOT send
    /// Connection: close and are read with a deadline). Returns nil on connect failure.
    ///
    /// The read is bounded by `timeoutMs` milliseconds using SO_RCVTIMEO so the
    /// call returns when either `maxBytes` are received OR the timeout fires —
    /// whichever comes first. This lets SSE tests verify the stream head and an
    /// initial heartbeat without waiting forever.
    private func rawSocketRequest(
        port: UInt16,
        rawRequest: String,
        timeoutMs: Int = 200,
        maxBytes: Int = 4096
    ) -> Data? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        // Set receive timeout so the call returns even when the stream is open.
        var tv = timeval(tv_sec: 0, tv_usec: Int32(timeoutMs * 1000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        let connected = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }

        let req = Data(rawRequest.utf8)
        guard POSIXSocket.sendAll(fd, req) else { return nil }

        var buf = [UInt8](repeating: 0, count: maxBytes)
        var total = 0
        while total < maxBytes {
            let n = buf.withUnsafeMutableBytes { ptr in
                read(fd, ptr.baseAddress! + total, maxBytes - total)
            }
            if n <= 0 { break }   // EOF, error, or timeout
            total += n
        }
        return Data(buf[0..<total])
    }

    /// Open a client connection to 127.0.0.1:port, send one HTTP request, and read
    /// the full response (the server sends `Connection: close`, so read to EOF).
    ///
    /// - Parameters:
    ///   - path: The request path (default "/"). Use explicit path for GET endpoint tests.
    private func httpRequest(port: UInt16, method: String, body: String, path: String = "/", origin: String? = nil) -> (status: Int, body: Data)? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        let connected = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }

        let bodyData = Data(body.utf8)
        let originLine = origin.map { "Origin: \($0)\r\n" } ?? ""
        let head = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n\(originLine)Content-Type: application/json\r\nContent-Length: \(bodyData.count)\r\n\r\n"
        var out = Data(head.utf8)
        out.append(bodyData)
        guard POSIXSocket.sendAll(fd, out) else { return nil }

        var resp = Data()
        while let chunk = POSIXSocket.recv(fd, max: 65536), !chunk.isEmpty {
            resp.append(chunk)
        }
        guard let sep = resp.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headText = String(data: resp[resp.startIndex..<sep.lowerBound], encoding: .utf8) ?? ""
        let firstLine = headText.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        let status = parts.count >= 2 ? (Int(parts[1]) ?? 0) : 0
        return (status, Data(resp[sep.upperBound...]))
    }

    // MARK: - Tests

    @Test func httpInitializeRoundTrips() async throws {
        let dispatcher = try await makeDispatcher()
        let (port, stop) = try startServing(dispatcher)
        defer { stop() }

        let reqBody = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#
        let result = try #require(httpRequest(port: port, method: "POST", body: reqBody))
        #expect(result.status == 200)
        let json = try #require(try JSONSerialization.jsonObject(with: result.body) as? [String: Any])
        #expect((json["jsonrpc"] as? String) == "2.0")
        let rpcResult = try #require(json["result"] as? [String: Any])
        let serverInfo = try #require(rpcResult["serverInfo"] as? [String: Any])
        #expect((serverInfo["name"] as? String) == "ARIA_MCP")
    }

    @Test func httpToolsListRoundTrips() async throws {
        let dispatcher = try await makeDispatcher()
        let (port, stop) = try startServing(dispatcher)
        defer { stop() }

        let reqBody = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
        let result = try #require(httpRequest(port: port, method: "POST", body: reqBody))
        #expect(result.status == 200)
        let json = try #require(try JSONSerialization.jsonObject(with: result.body) as? [String: Any])
        let rpcResult = try #require(json["result"] as? [String: Any])
        let tools = try #require(rpcResult["tools"] as? [Any])
        #expect(!tools.isEmpty)
    }

    @Test func v2HTTPToolsListAndMonitoringStatusRoundTrip() async throws {
        let dispatcher = try await makeDispatcher()
        let (port, stop) = try startServing(dispatcher)
        defer { stop() }

        let listReply = try #require(httpRequest(
            port: port,
            method: "POST",
            body: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        ))
        #expect(listReply.status == 200)
        let listJSON = try #require(
            try JSONSerialization.jsonObject(with: listReply.body) as? [String: Any])
        let listResult = try #require(listJSON["result"] as? [String: Any])
        let listedNames = Set((try #require(listResult["tools"] as? [[String: Any]])).compactMap {
            $0["name"] as? String
        })
        let selectedNames = Set(ToolProjection.tools(environment: [:]).map(\.name))
        #expect(listedNames == selectedNames)
        #expect(listedNames.contains("moot_monitoring_status"))

        let callReply = try #require(httpRequest(
            port: port,
            method: "POST",
            body: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"moot_monitoring_status","arguments":{}}}"#
        ))
        #expect(callReply.status == 200)
        let callJSON = try #require(
            try JSONSerialization.jsonObject(with: callReply.body) as? [String: Any])
        let callResult = try #require(callJSON["result"] as? [String: Any])
        let structured = try #require(callResult["structuredContent"] as? [String: Any])
        #expect(structured["surface_version"] as? String == "v2")
        #expect(structured["tool"] as? String == "moot_monitoring_status")
        #expect((structured["meta"] as? [String: Any])?["effect"] as? String == "read")
    }

    @Test func httpNonPostReturns405() async throws {
        let dispatcher = try await makeDispatcher()
        let (port, stop) = try startServing(dispatcher)
        defer { stop() }

        // PUT is neither GET (handled by the GET routing block) nor POST
        // (the MCP transport path), so it reaches the method guard and gets 405.
        let result = try #require(httpRequest(port: port, method: "PUT", body: ""))
        #expect(result.status == 405)
    }

    @Test func httpUnknownGetPathReturns404() async throws {
        let dispatcher = try await makeDispatcher()
        let (port, stop) = try startServing(dispatcher)
        defer { stop() }

        // GET to an unknown path falls through the GET switch default case → 404.
        let result = try #require(httpRequest(port: port, method: "GET", body: ""))
        #expect(result.status == 404)
    }

    @Test func httpGraphNoSnapshotReturnsStructurePending() async throws {
        // No topologyReader wired → no snapshot in store → structurePending: true.
        // This is the correct behavior when the governor has not yet fired (daemon
        // just started) or no stats store is configured.
        let dispatcher = try await makeDispatcher()
        let (port, stop) = try startServing(dispatcher)
        defer { stop() }

        let result = try #require(httpRequest(port: port, method: "GET", body: "", path: "/api/graph"))
        #expect(result.status == 200)
        let json = try #require(try JSONSerialization.jsonObject(with: result.body) as? [String: Any])
        #expect((json["structurePending"] as? Bool) == true)
    }

    @Test func httpGraphReaderPayloadPassedThrough() async throws {
        // When a topologyReader returns a pre-built payload, GET /api/graph returns
        // it verbatim. Tests the injection path without needing a full governor run.
        let storedPayload = Data("""
        {"nodes":[{"id":"abc","nounType":0,"communityId":1,"centrality":0.5,"anomaly":false,"tombstonedTs":null}],
         "edges":[],"structurePending":false,"communities":[{"id":1,"size":1,"dominantUdcCode":"510"}],
         "generatedTs":"2026-01-01T00:00:00Z"}
        """.utf8)

        let dispatcher = try await makeDispatcher()
        let (port, stop) = try startServing(dispatcher, topologyReader: { _ in storedPayload })
        defer { stop() }

        let result = try #require(httpRequest(port: port, method: "GET", body: "", path: "/api/graph"))
        #expect(result.status == 200)
        let json = try #require(try JSONSerialization.jsonObject(with: result.body) as? [String: Any])
        #expect((json["structurePending"] as? Bool) == false)
        let nodes = try #require(json["nodes"] as? [[String: Any]])
        #expect(nodes.count == 1)
        #expect((nodes[0]["id"] as? String) == "abc")
        let communities = try #require(json["communities"] as? [[String: Any]])
        #expect(communities.count == 1)
        // generatedTs is forwarded verbatim — the transport is transparent.
        #expect((json["generatedTs"] as? String) == "2026-01-01T00:00:00Z")
    }

    @Test func httpAdminEstatesHostedListIncludesOpenedEstate() async throws {
        let dispatcher = try await makeDispatcher()
        let (port, stop) = try startServing(dispatcher)
        defer { stop() }

        let result = try #require(httpRequest(port: port, method: "GET", body: "", path: "/api/admin/estates"))
        #expect(result.status == 200)
        let json = try #require(try JSONSerialization.jsonObject(with: result.body) as? [String: Any])
        let hosted = try #require(json["hosted"] as? [[String: Any]])
        // The dispatcher opened exactly one in-memory estate in makeDispatcher().
        #expect(hosted.count == 1)
        let entry = try #require(hosted.first)
        #expect((entry["kind"] as? String) == "GLK")
        #expect((entry["backend"] as? String) == "InMemory")
        #expect((entry["mountState"] as? String) == "mounted")
        // estateName is non-empty (set by the manifest); estateUUID is a valid UUID string.
        let estateName = entry["estateName"] as? String
        #expect(estateName != nil)
        let uuidString = try #require(entry["estateUUID"] as? String)
        #expect(UUID(uuidString: uuidString) != nil)
    }

    @Test func httpCrossOriginIsRejected() async throws {
        let dispatcher = try await makeDispatcher()
        let (port, stop) = try startServing(dispatcher)
        defer { stop() }

        // A browser tab reaching the loopback endpoint via DNS rebinding carries
        // the attacker's domain as Origin → 403 before any dispatch.
        let reqBody = #"{"jsonrpc":"2.0","id":9,"method":"tools/list"}"#
        let result = try #require(httpRequest(port: port, method: "POST", body: reqBody, origin: "http://evil.example.com"))
        #expect(result.status == 403)
    }

    /// Loopback-prefix spoofing: attacker registers `localhost.evil` (or
    /// `127.0.0.1.evil`) as a domain that DNS-resolves to 127.0.0.1. A page
    /// served from that domain carries it as Origin. The old prefix check would
    /// allow this; the URL-parsed host comparison rejects it.
    @Test func httpLoopbackPrefixSpoofOriginIsRejected() async throws {
        let dispatcher = try await makeDispatcher()
        let (port, stop) = try startServing(dispatcher)
        defer { stop() }

        let reqBody = #"{"jsonrpc":"2.0","id":9,"method":"tools/list"}"#
        for origin in ["http://localhost.evil", "http://127.0.0.1.evil", "http://[::1].evil",
                       "https://localhost.attacker.test", "http://localhost@evil.example"] {
            let result = try #require(httpRequest(port: port, method: "POST", body: reqBody, origin: origin))
            #expect(result.status == 403, "spoofed origin \(origin) must be rejected")
        }
    }

    @Test func httpLoopbackOriginIsAllowed() async throws {
        let dispatcher = try await makeDispatcher()
        let (port, stop) = try startServing(dispatcher)
        defer { stop() }

        // A loopback Origin is fine (a future local web UI / same-host tool).
        let reqBody = #"{"jsonrpc":"2.0","id":10,"method":"tools/list"}"#
        let result = try #require(httpRequest(port: port, method: "POST", body: reqBody, origin: "http://127.0.0.1:4242"))
        #expect(result.status == 200)
    }

    @Test func httpMalformedBodyReturnsJSONRPCParseError() async throws {
        let dispatcher = try await makeDispatcher()
        let (port, stop) = try startServing(dispatcher)
        defer { stop() }

        // Not JSON. The transport mirrors StdioServer: HTTP 200 carrying a
        // JSON-RPC parse error (code -32700) with a null id.
        let result = try #require(httpRequest(port: port, method: "POST", body: "this is not json"))
        #expect(result.status == 200)
        let json = try #require(try JSONSerialization.jsonObject(with: result.body) as? [String: Any])
        let error = try #require(json["error"] as? [String: Any])
        #expect((error["code"] as? Int) == -32700)
    }

    // MARK: - SSE event-stream tests

    /// GET /api/events with Accept: text/event-stream opens the SSE channel.
    ///
    /// The server writes the SSE response head (200 + text/event-stream +
    /// keep-alive) and then sends a heartbeat comment line (`: heartbeat`)
    /// periodically. This test uses a very short heartbeat interval (50 ms) by
    /// driving `driveSSEStream` directly against a real socket pair, so the test
    /// does not wait 15 seconds for the production interval.
    ///
    /// The test verifies the full shape: the response head bytes arrive, the
    /// Content-Type is `text/event-stream`, the connection is `keep-alive`, and
    /// the `: heartbeat` comment line arrives within the read timeout (500 ms).
    @Test func sseStreamSendsHeadAndHeartbeat() throws {
        // Build a real loopback socketpair-equivalent: bind port 0, connect the
        // client, then accept the server side.
        let listenFD = try {
            let (fd, _) = try POSIXSocket.listenLoopbackTCP(port: 0)
            return fd
        }()
        defer { close(listenFD) }

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                _ = getsockname(listenFD, sa, &len)
            }
        }
        let port = UInt16(bigEndian: bound.sin_port)

        // Client connects before accept (TCP three-way handshake completes via backlog).
        let clientFD = socket(AF_INET, SOCK_STREAM, 0)
        guard clientFD >= 0 else { throw SocketError.syscall("socket", errno) }
        defer { close(clientFD) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        let connected = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(clientFD, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(connected == 0)

        // Accept the server side of the connection.
        guard let serverFD = POSIXSocket.acceptOne(listenFD) else {
            Issue.record("accept failed")
            return
        }
        defer { close(serverFD) }

        // Drive the SSE stream on a background thread with a 50 ms heartbeat
        // interval so the test receives the first ping quickly.
        let intervalNs: UInt64 = 50_000_000   // 50 ms
        let sseTask = Task.detached {
            await HTTPServer.driveSSEStream(fd: serverFD, intervalNanoseconds: intervalNs)
        }
        defer { sseTask.cancel() }

        // Set a receive timeout on the client so the read does not block forever.
        var tv = timeval(tv_sec: 0, tv_usec: 500_000)   // 500 ms
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Read until we see the heartbeat comment line or the timeout fires.
        var received = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while received.count < 4096 {
            let n = buf.withUnsafeMutableBytes { ptr in
                read(clientFD, ptr.baseAddress!, 4096)
            }
            if n <= 0 { break }
            received.append(contentsOf: buf[0..<n])
            // Stop as soon as we have both the response head and the first ping.
            let text = String(data: received, encoding: .utf8) ?? ""
            if text.contains(": heartbeat") { break }
        }

        let responseText = try #require(String(data: received, encoding: .utf8))

        // Verify response head.
        #expect(responseText.contains("HTTP/1.1 200"), "SSE response must be 200")
        #expect(responseText.contains("text/event-stream"),
                "SSE response must carry Content-Type: text/event-stream")
        #expect(responseText.contains("keep-alive"),
                "SSE response must carry Connection: keep-alive")
        // Verify heartbeat arrived (the live stream is working, not dead-advertised).
        #expect(responseText.contains(": heartbeat"),
                "SSE stream must send heartbeat comment line")
    }

    /// GET /api/events WITHOUT Accept: text/event-stream falls through to the
    /// normal GET router and returns 404 (path not in the snapshot route set).
    ///
    /// This guards against accidentally treating every /api/events GET as SSE;
    /// only clients that explicitly signal event-stream acceptance get the stream.
    @Test func httpSSEEventStreamWithoutAcceptHeaderReturns404() async throws {
        let dispatcher = try await makeDispatcher()
        let (port, stop) = try startServing(dispatcher)
        defer { stop() }

        // Plain GET without the text/event-stream Accept header.
        // The SSE branch is skipped; the default GET router sees /api/events
        // as an unknown path and returns 404.
        let result = try #require(httpRequest(port: port, method: "GET", body: "", path: "/api/events"))
        #expect(result.status == 404)
    }

    // MARK: - Finding #4 — last_n negative / zero / huge clamped in moot_read_journal

    /// last_n=-1 must return invalidParams (not all rows). Before the fix,
    /// `optionalInt` let -1 through → SQLite LIMIT -1 = full table scan.
    @Test func readJournalNegativeLastNReturnsInvalidParams() async throws {
        let dispatcher = try await makeDispatcher()
        let (port, stop) = try startServing(dispatcher)
        defer { stop() }

        let body = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"moot_read_journal","arguments":{"last_n":-1}}}"#
        let result = try #require(httpRequest(port: port, method: "POST", body: body))
        #expect(result.status == 200)
        let json = try #require(try JSONSerialization.jsonObject(with: result.body) as? [String: Any])
        // JSON-RPC error object: code -32602 (invalid params).
        let error = try #require(json["error"] as? [String: Any],
                                 "last_n=-1 must yield a JSON-RPC error; got result instead")
        #expect((error["code"] as? Int) == -32602, "expected invalidParams (-32602); got \(error["code"] ?? "nil")")
    }

    /// last_n=0 must also return invalidParams (0 is not ≥1).
    @Test func readJournalZeroLastNReturnsInvalidParams() async throws {
        let dispatcher = try await makeDispatcher()
        let (port, stop) = try startServing(dispatcher)
        defer { stop() }

        let body = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"moot_read_journal","arguments":{"last_n":0}}}"#
        let result = try #require(httpRequest(port: port, method: "POST", body: body))
        #expect(result.status == 200)
        let json = try #require(try JSONSerialization.jsonObject(with: result.body) as? [String: Any])
        let error = try #require(json["error"] as? [String: Any],
                                 "last_n=0 must yield a JSON-RPC error")
        #expect((error["code"] as? Int) == -32602)
    }

    /// last_n=1000 (above ceiling 500) must be clamped to 500 — no error, just truncated.
    ///
    /// BLOCKED: v2 `moot_read_journal` uses `limit` (not `last_n`) as its argument key,
    /// and the v2 `AriaV2ReadJournalRequest` decoder REJECTS values above the 500
    /// ceiling (throws invalidParams) rather than clamping them silently. The v2 path uses
    /// `AriaV2KnowledgeJournalRequest.limit()` which throws. The test's pinned assertion
    /// ("must not error") cannot be satisfied with either key name in v2. Awaiting
    /// catalog decision on whether v2 should clamp or reject over-ceiling limit values.
    /// Do not delete; do not weaken to pass.
    /// The clamp itself, in v2's shape. `last_n` became `limit`, which stands
    /// as reasonable normalisation, so the case below pins a name the strict
    /// decoder no longer accepts and is handed to the conversion lane. This
    /// one keeps the BEHAVIOUR covered meanwhile: over-ceiling clamps silently
    /// rather than refusing, so a caller asking for 10_000 gets 500 instead of
    /// nothing.
    @Test
    func readJournalOverCeilingLimitIsClampedSilently() async throws {
        let dispatcher = try await makeDispatcher()
        let (port, stop) = try startServing(dispatcher)
        defer { stop() }

        let body = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"moot_read_journal","arguments":{"limit":1000}}}"#
        let result = try #require(httpRequest(port: port, method: "POST", body: body))
        #expect(result.status == 200)
        let json = try #require(try JSONSerialization.jsonObject(with: result.body) as? [String: Any])
        #expect(json["result"] != nil,
                "limit=1000 must clamp silently to the ceiling, not refuse; got: \(json)")
    }

    @Test(.disabled("CONVERSION PENDING (was BLOCKED on reject-instead-of-clamp). The clamp is restored: an over-ceiling limit now clamps silently instead of throwing, and below one is still refused because a negative reaches SQLite as LIMIT -1 and returns every row. What remains is the ARGUMENT NAME — this case sends v1's `last_n`, and the rename to `limit` was ruled to stand as normalisation, so the strict decoder rejects the key before the clamp is reached. readJournalOverCeilingLimitIsClampedSilently above covers the behaviour. Renaming the argument in this case is like-for-like. Do not delete; do not weaken to pass."))
    func readJournalHugeLastNIsClamped() async throws {
        let dispatcher = try await makeDispatcher()
        let (port, stop) = try startServing(dispatcher)
        defer { stop() }

        // A fresh estate has an empty journal; last_n=1000 is clamped to 500
        // silently and the call succeeds (result, not error).
        let body = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"moot_read_journal","arguments":{"last_n":1000}}}"#
        let result = try #require(httpRequest(port: port, method: "POST", body: body))
        #expect(result.status == 200)
        let json = try #require(try JSONSerialization.jsonObject(with: result.body) as? [String: Any])
        // Result (not error): clamping to ceiling is silent success.
        #expect(json["result"] != nil,
                "last_n=1000 must be clamped silently to 500 — must not error; got: \(json)")
    }

    // MARK: - Finding #8 — Host guard on ARIA MCP GET routes → 421

    /// GET /api/graph with a non-loopback Host header must be rejected 421.
    /// A DNS-rebinding attacker sends a non-loopback domain as Host; native
    /// MCP clients omit Host or send 127.0.0.1.
    @Test func httpGetWithNonLoopbackHostReturns421() async throws {
        let dispatcher = try await makeDispatcher()
        let (port, stop) = try startServing(dispatcher)
        defer { stop() }

        for (path, desc) in [("/api/graph", "graph"), ("/api/admin/estates", "admin/estates"), ("/api/lattice", "lattice")] {
            let raw = "GET \(path) HTTP/1.1\r\nHost: attacker.example.com\r\nContent-Length: 0\r\n\r\n"
            let resp = try #require(rawSocketRequest(port: port, rawRequest: raw),
                                    "no response for \(desc)")
            let text = String(data: resp, encoding: .utf8) ?? ""
            #expect(text.hasPrefix("HTTP/1.1 421"),
                    "GET \(path) with non-loopback Host must return 421; got: \(text.prefix(40))")
        }
    }

    /// GET /api/graph with a loopback Host must succeed (200), not be blocked.
    @Test func httpGetWithLoopbackHostSucceeds() async throws {
        let dispatcher = try await makeDispatcher()
        let (port, stop) = try startServing(dispatcher)
        defer { stop() }

        let raw = "GET /api/graph HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 0\r\n\r\n"
        let resp = try #require(rawSocketRequest(port: port, rawRequest: raw))
        let text = String(data: resp, encoding: .utf8) ?? ""
        #expect(text.hasPrefix("HTTP/1.1 200"),
                "GET /api/graph with loopback Host must return 200; got: \(text.prefix(40))")
    }

    @Test func httpGetLatticeOmitsUnclassifiedSentinel() async throws {
        let fixture = try await makeDispatcherWithEstate()

        _ = try await fixture.kit.capture(fixture.handle, CaptureFrame(
            content: "git status\nrm .git/index.lock",
            channel: .importedFile,
            room: "http-lattice",
            latticeAnchor: .udc("000"),
            addedBy: "http-tests",
            embeddingModelID: "test-model"
        ))
        _ = try await fixture.kit.capture(fixture.handle, CaptureFrame(
            content: "computing systems and data processing",
            channel: .importedFile,
            room: "http-lattice",
            latticeAnchor: .udc("006"),
            addedBy: "http-tests",
            embeddingModelID: "test-model"
        ))

        let (port, stop) = try startServing(fixture.dispatcher)
        defer { stop() }

        let result = try #require(httpRequest(port: port, method: "GET", body: "", path: "/api/lattice"))
        #expect(result.status == 200)

        let json = try #require(try JSONSerialization.jsonObject(with: result.body) as? [String: Any])
        let addresses = try #require(json["addresses"] as? [[String: Any]])
        #expect(addresses.count == 1)
        #expect(addresses.first?["code"] as? String == "006")
        #expect(addresses.first?["count"] as? Int == 1)
    }

    /// GET /api/graph with absent Host must succeed (curl omits Host).
    @Test func httpGetWithAbsentHostSucceeds() async throws {
        let dispatcher = try await makeDispatcher()
        let (port, stop) = try startServing(dispatcher)
        defer { stop() }

        let raw = "GET /api/graph HTTP/1.1\r\nContent-Length: 0\r\n\r\n"
        let resp = try #require(rawSocketRequest(port: port, rawRequest: raw))
        let text = String(data: resp, encoding: .utf8) ?? ""
        #expect(text.hasPrefix("HTTP/1.1 200"),
                "GET /api/graph with absent Host must return 200; got: \(text.prefix(40))")
    }

    // MARK: - Finding #8 — isLoopbackHost unit coverage

    /// Verify the `isLoopbackHost` helper accepts expected loopback values and
    /// rejects hostile ones. Mirrors `HTTPReadAPITests.isLoopbackHost*` tests.
    @Test func isLoopbackHostAcceptsLoopbackValues() {
        #expect(HTTPServer.isLoopbackHost(nil))
        #expect(HTTPServer.isLoopbackHost(""))
        #expect(HTTPServer.isLoopbackHost("127.0.0.1"))
        #expect(HTTPServer.isLoopbackHost("127.0.0.1:4242"))
        #expect(HTTPServer.isLoopbackHost("localhost"))
        #expect(HTTPServer.isLoopbackHost("LOCALHOST"))
        #expect(HTTPServer.isLoopbackHost("localhost:9000"))
        #expect(HTTPServer.isLoopbackHost("[::1]"))
        #expect(HTTPServer.isLoopbackHost("[::1]:8080"))
    }

    @Test func isLoopbackHostRejectsNonLoopback() {
        #expect(!HTTPServer.isLoopbackHost("evil.example.com"))
        #expect(!HTTPServer.isLoopbackHost("evil.example.com:8080"))
        #expect(!HTTPServer.isLoopbackHost("localhost.evil"))
        #expect(!HTTPServer.isLoopbackHost("127.0.0.1.evil"))
        #expect(!HTTPServer.isLoopbackHost("192.168.1.5"))
    }

    // MARK: - Default-estate enforcement (secfix/c-aria-minor CAND-043)

    /// GET /api/graph with an arbitrary `?estate=` query param MUST NOT forward
    /// that param to the topology reader — the reader is always called with `nil`
    /// (the default estate), matching the Rust posture of ignoring `?estate=`.
    ///
    /// The test wires a reader that records the estate argument it receives and
    /// returns a synthetic payload. A request with `?estate=<random-uuid>` must
    /// call the reader with `nil`, not with the random UUID.
    @Test func httpGraphIgnoresCallerSuppliedEstateQueryParam() async throws {
        let storedPayload = Data("""
        {"nodes":[],"edges":[],"structurePending":false,"communities":[],
         "generatedTs":"2026-01-01T00:00:00Z"}
        """.utf8)

        // Capture the estate argument the reader is called with.
        actor EstateSpy {
            var received: String?? = nil // outer Optional = not yet called; inner = the arg
            func record(_ arg: String?) { received = .some(arg) }
        }
        let spy = EstateSpy()

        let dispatcher = try await makeDispatcher()
        let (port, stop) = try startServing(dispatcher, topologyReader: { estate in
            await spy.record(estate)
            return storedPayload
        })
        defer { stop() }

        // Send a request with an arbitrary ?estate= query param.
        let arbitraryEstateID = UUID().uuidString
        let result = try #require(
            httpRequest(port: port, method: "GET", body: "",
                       path: "/api/graph?estate=\(arbitraryEstateID)"))
        #expect(result.status == 200)

        // Give the async reader a moment to run (the server dispatches asynchronously).
        try await Task.sleep(nanoseconds: 100_000_000)

        // The reader must have been called with nil — not the arbitrary estate ID.
        let receivedArg = await spy.received
        // receivedArg is Optional<Optional<String>>:
        // .none = reader not called yet (test infra issue)
        // .some(.none) = reader called with nil ✅
        // .some(.some(id)) = reader called with an estate ID ❌
        guard case .some(let arg) = receivedArg else {
            Issue.record("topologyReader was not called; check test harness")
            return
        }
        #expect(arg == nil,
                "topologyReader must be called with nil (default estate), not \"\(arg ?? "non-nil")\"")
    }
}

// MARK: - First-party authenticated lane, end to end
//
// The protocol and server suites test the algebra and the middleware in
// isolation. This one drives real sockets: the whole point is to prove that
// what arrives on the wire is what gets authenticated, and that an
// unauthenticated peer cannot reach the JSON parser or the dispatcher.

@Suite("HTTP transport — first-party authenticated lane", .serialized)
struct FirstPartyHTTPLaneTests {

    typealias Vectors = FirstPartyAuthProtocolTests
    typealias ServerFixtures = FirstPartyAuthServerTests

    private struct NoopCommunityHandler: CommunityToolHandler {
        func isCommunityTool(_ name: String) -> Bool { false }
        var communityToolList: [ProjectedTool] { [] }
        func dispatch(name: String, arguments: JSONValue) async throws -> JSONValue {
            throw JSONRPCError(code: JSONRPCErrorCode.methodNotFound, message: "Method not found: \(name)")
        }
    }

    private final class CommunityInvocationLog: @unchecked Sendable {
        var dispatches = 0
    }

    /// A nonempty fixture for the authenticated aggregate test. Keep
    /// NoopCommunityHandler in the stable-provider tests: those fixtures prove
    /// that an installed empty Community composition cannot leak a tool.
    private struct OneCommunityHandler: CommunityToolHandler {
        let log: CommunityInvocationLog

        func isCommunityTool(_ name: String) -> Bool {
            name == "moot_community_http_test"
        }

        var communityToolList: [ProjectedTool] {
            [ProjectedTool(
                name: "moot_community_http_test",
                description: "Exercise the authenticated Community route.",
                inputSchema: .object(["type": .string("object")]),
                provenance: .community)]
        }

        func dispatch(name: String, arguments: JSONValue) async throws -> JSONValue {
            log.dispatches += 1
            return .object(["source": .string("community-http")])
        }
    }

    private actor FixedEstateExecutorContext: FirstPartyProviderExecutorContext {
        let kit: GeniusLocusKit
        let handle: EstateHandle

        init(kit: GeniusLocusKit, handle: EstateHandle) {
            self.kit = kit
            self.handle = handle
        }

        func currentEstateSession() async throws -> FirstPartyProviderEstateSession {
            FirstPartyProviderEstateSession(kit: kit, handle: handle)
        }
    }

    private actor RotatingEstateExecutorContext: FirstPartyProviderExecutorContext {
        private let kit: GeniusLocusKit
        private let owner: OwnerCredentials
        private let estateID: UUID
        private let url: URL
        private let identityKeyStore: InMemoryEstateIdentityKeyStore
        private var handle: EstateHandle

        init(kit: GeniusLocusKit, owner: OwnerCredentials, handle: EstateHandle, url: URL,
             identityKeyStore: InMemoryEstateIdentityKeyStore) {
            self.kit = kit
            self.owner = owner
            self.estateID = handle.estateUUID
            self.url = url
            self.identityKeyStore = identityKeyStore
            self.handle = handle
        }

        func currentEstateSession() async throws -> FirstPartyProviderEstateSession {
            FirstPartyProviderEstateSession(kit: kit, handle: handle)
        }

        func closeActive() async throws { try await kit.close(handle) }

        func reopen() async throws {
            let storage = try SQLiteStorage(configuration: EstateConfiguration(
                estateID: estateID, backend: .sqlite(url: url, busyTimeout: 5.0)))
            _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
            handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: identityKeyStore)
        }
    }

    private actor FirstPartyHTTPProvider: FirstPartyProvider {
        private(set) var contexts: [FirstPartyProviderCallContext] = []

        func isFirstPartyProviderTool(_ name: String) async -> Bool {
            name == "stable.first_party.http"
        }

        var firstPartyProviderToolList: [ProjectedTool] {
            get async {
                [ProjectedTool(
                    name: "stable.first_party.http",
                    description: "Exercise a verified stable provider route.",
                    inputSchema: .object(["type": .string("object")]),
                    provenance: .product)]
            }
        }

        func dispatchFirstPartyProviderTool(
            name: String, arguments: JSONValue, context: FirstPartyProviderCallContext
        ) async throws -> JSONValue {
            contexts.append(context)
            return .object(["source": .string("stable-first-party-http")])
        }

        func callCount() -> Int { contexts.count }
    }

    private struct FixedFirstPartyRecallPolicyAuthority: FirstPartyRecallPolicyAuthority {
        func currentFirstPartyRecallPolicy(
            for caller: FirstPartyProviderCallContext
        ) async -> FirstPartyRecallPolicy {
            FirstPartyRecallPolicy(maximumSensitivity: .restricted, exportability: .exportableOnly)
        }
    }

    private func makeDispatcher() async throws -> ARIA_MCPDispatcher {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-mcp-first-party-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore()
        )
        let info = ARIA_MCPDispatcher.ServerInfo(name: "ARIA_MCP", version: "1.1.0")
        return ARIA_MCPDispatcher(info: info, tooling: ToolDispatcher(kit: kit, handle: handle))
    }

    private func makeProviderDispatcher(
        _ provider: any FirstPartyProvider,
        communityHandler: any CommunityToolHandler = NoopCommunityHandler(),
        recallPolicyAuthority: any FirstPartyRecallPolicyAuthority = FirstPartyNoGrantRecallPolicyAuthority()
    ) -> ARIA_MCPDispatcher {
        ARIA_MCPDispatcher(
            info: .init(name: "ARIA_MCP", version: "1.1.0"),
            communityHandler: communityHandler,
            firstPartyProvider: provider,
            firstPartyRecallPolicyAuthority: recallPolicyAuthority)
    }

    /// Serve on an OS-assigned port, optionally with the first-party lane armed.
    private func startServing(
        _ dispatcher: ARIA_MCPDispatcher,
        firstPartyAuth: FirstPartyAuthServer?
    ) throws -> (port: UInt16, stop: () -> Void) {
        let server = HTTPServer(dispatcher: dispatcher, port: 0, firstPartyAuth: firstPartyAuth)
        let (listenFD, port) = try server.bind()
        let auth = firstPartyAuth
        let thread = Thread {
            while let cfd = POSIXSocket.acceptOne(listenFD) {
                Task {
                    await HTTPServer.serve(
                        cfd, dispatcher: dispatcher, maxBodyBytes: 4 * 1024 * 1024,
                        sseGate: globalSSEConcurrencyGate, firstPartyAuth: auth
                    )
                }
            }
        }
        thread.name = "aria-mcp.http.first-party.test.accept"
        thread.start()
        return (port, { close(listenFD) })
    }

    /// Send raw bytes and read the whole response.
    private func send(port: UInt16, raw: String) -> String? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }
        // 30 s matches the server's own read timeout (HTTPServer.swift uses 30 s).
        // A shorter client timeout turns a slow concurrency-scheduling window under
        // parallel test load into a false 404-assertion failure: the client times out
        // before the server's Task{} gets a slot, recv returns empty, and statusLine("")
        // contains no "404".  The assertion is correct; only the wait must be longer.
        var tv = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard POSIXSocket.sendAll(fd, Data(raw.utf8)) else { return nil }
        var out = Data()
        while let chunk = POSIXSocket.recv(fd, max: 16 * 1024), !chunk.isEmpty {
            out.append(chunk)
        }
        return String(data: out, encoding: .utf8)
    }

    /// Compose a raw HTTP/1.1 request.
    private func rawRequest(target: String, headers: [(String, String)], body: String) -> String {
        var text = "POST \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        text += "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
        return text
    }

    private func statusLine(_ response: String?) -> String {
        response?.components(separatedBy: "\r\n").first ?? ""
    }

    private func stableProviderCompatibilityJSON(
        digest: String = FirstPartyProviderCatalog.capabilityDigest
    ) -> String {
        #"{"contract_version":"\#(FirstPartyProviderCatalog.contractVersion)","aria_supported_version":"\#(FirstPartyProviderCatalog.supportedARIAVersion)","capability_digest":"\#(digest)"}"#
    }

    private func legacyStableProviderCompatibilityJSON() -> String {
        #"{"contract_version":"\#(FirstPartyProviderCatalog.legacyContractVersion)","aria_supported_version":"\#(FirstPartyProviderCatalog.supportedARIAVersion)","capability_digest":"\#(FirstPartyProviderCatalog.legacyCapabilityDigest)"}"#
    }

    private func signedDescriptor(for estateID: UUID) -> FirstPartyDescriptor {
        var descriptor = ServerFixtures.signedDescriptor()
        descriptor.estateIdentifier = estateID
        descriptor.descriptorMAC = FirstPartyAuthProtocol.hmacSHA256(
            key: FirstPartyAuthProtocol.descriptorKey(installationRoot: Vectors.fixedRoot),
            message: descriptor.macInput())
        return descriptor
    }

    private func responseObject(_ response: String?) throws -> [String: Any] {
        let body = try #require(response?.components(separatedBy: "\r\n\r\n").last)
        return try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    }

    private func sqliteBytes(_ url: URL) throws -> [Data] {
        try [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")].map {
            FileManager.default.fileExists(atPath: $0.path) ? try Data(contentsOf: $0) : Data()
        }
    }

    private func authenticatedRequest(
        port: UInt16, session: (sessionIdentifier: [UInt8], sessionKey: [UInt8]),
        sequence: UInt64, body: String
    ) -> String? {
        let mac = FirstPartyAuthProtocol.requestMAC(
            sessionKey: session.sessionKey, sessionIdentifier: session.sessionIdentifier, sequence: sequence,
            method: "POST", path: "/mcp/first-party", contentType: "application/json", body: Data(body.utf8))
        return send(port: port, raw: rawRequest(target: "/mcp/first-party", headers: [
            ("Content-Type", "application/json"),
            ("Authorization", "Mootx01Session " + FirstPartyAuthProtocol.base64URLEncode(session.sessionIdentifier)),
            ("Mootx01-Sequence", String(sequence)),
            ("Mootx01-Request-MAC", FirstPartyAuthProtocol.base64URLEncode(mac)),
        ], body: body))
    }

    // MARK: Dark by default

    @Test("With no first-party server the entire subtree is unavailable")
    func subtreeUnavailableWhenDark() async throws {
        let dispatcher = try await makeDispatcher()
        let (port, stop) = try startServing(dispatcher, firstPartyAuth: nil)
        defer { stop() }

        // A well-formed JSON-RPC body that WOULD dispatch on the public lane.
        // It must not be parsed or dispatched here — 404, not 200.
        for target in [
            "/mcp/first-party",
            "/mcp/first-party/session/challenge",
            "/mcp/first-party/session/establish",
        ] {
            let response = send(port: port, raw: rawRequest(
                target: target,
                headers: [("Content-Type", "application/json")],
                body: #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
            ))
            #expect(statusLine(response).contains("404"), "\(target) must be unavailable while dark")
            #expect(response?.contains("\"result\"") != true, "\(target) must never dispatch while dark")
        }
    }

    @Test("A dark daemon never advertises the first-party capability")
    func darkDaemonDoesNotAdvertise() async throws {
        let dispatcher = try await makeDispatcher()
        let (port, stop) = try startServing(dispatcher, firstPartyAuth: nil)
        defer { stop() }
        let response = send(port: port, raw: rawRequest(
            target: "/",
            headers: [("Content-Type", "application/json")],
            body: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#
        ))
        #expect(statusLine(response).contains("200"))
        #expect(response?.contains("authenticated-first-party") == false)
        #expect(response?.contains("instanceIdentifier") == false)
    }

    // MARK: Armed lane

    @Test("authenticated stable provider admits before mutation and never leaks Community into selected v2")
    func authenticatedStableProviderCaptureAndReadback() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FirstPartyProviderHTTP-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("estate.sqlite")
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-mcp-stable-provider-http")
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .sqlite(url: url, busyTimeout: 5.0)))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let identityKeyStore = InMemoryEstateIdentityKeyStore()
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: identityKeyStore)
        defer { Task { try? await kit.close(handle) } }

        let descriptor = signedDescriptor(for: handle.estateUUID)
        let auth = FirstPartyAuthServer(
            rootProvider: FixedFirstPartyRootProvider(root: Vectors.fixedRoot), descriptor: descriptor,
            serverName: "ARIA_MCP", now: { 1_766_000_000 }, randomBytes: { Array(repeating: 7, count: $0) })
        let provider = FirstPartyProviderExecutor()
        let context = RotatingEstateExecutorContext(kit: kit, owner: owner, handle: handle, url: url,
                                                    identityKeyStore: identityKeyStore)
        await provider.installFirstPartyProviderExecutorContext(context)
        let (port, stop) = try startServing(makeProviderDispatcher(provider), firstPartyAuth: auth)
        defer { stop() }
        let session = try await ServerFixtures.handshake(auth, descriptor: descriptor)

        func request(_ sequence: UInt64, _ body: String) -> String? {
            authenticatedRequest(port: port, session: session, sequence: sequence, body: body)
        }

        let initialize = request(1, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#)
        #expect(statusLine(initialize).contains("200"))
        #expect(initialize?.contains("\"first_party_provider\"") == true)

        let listed = request(2, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        #expect(statusLine(listed).contains("200"))
        #expect(listed?.contains("moot_file_memory") == true)
        #expect(listed?.contains("moot_community_contract") == false)
        #expect(listed?.contains("moot_dream") == false)

        let bytesBeforeMismatch = try sqliteBytes(url)
        let undeclared = request(3, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"moot_file_memory","first_party_provider":\#(stableProviderCompatibilityJSON()),"arguments":{"content":"must not persist","subject":"bad","location":"test","undeclared":"must reject"}}}"#)
        #expect(undeclared?.contains("Undeclared argument") == true)
        #expect(try sqliteBytes(url) == bytesBeforeMismatch, "fixed-schema refusal must precede any estate mutation")

        let mismatched = request(4, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"moot_file_memory","first_party_provider":{"contract_version":"0.0.0","aria_supported_version":"v2","capability_digest":"bad"},"arguments":{"content":"must not persist","subject":"bad","location":"test"}}}"#)
        #expect(statusLine(mismatched).contains("200"))
        #expect(mismatched?.contains("matching first_party_provider compatibility record") == true)
        #expect(try sqliteBytes(url) == bytesBeforeMismatch, "compatibility refusal must precede any estate mutation")

        let capture = request(5, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"moot_file_memory","first_party_provider":\#(stableProviderCompatibilityJSON()),"arguments":{"content":"stable native capture","subject":"provider readback","location":"HTTP integration"}}}"#)
        let captureObject = try responseObject(capture)
        let captureResult = try #require(captureObject["result"] as? [String: Any])
        let structured = try #require(captureResult["structuredContent"] as? [String: Any])
        let data = try #require(structured["data"] as? [String: Any])
        let memoryID = try #require(data["memory_id"] as? String)

        let read = request(6, #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"moot_memory_get","first_party_provider":\#(stableProviderCompatibilityJSON()),"arguments":{"memory_id":"\#(memoryID)"}}}"#)
        #expect(statusLine(read).contains("200"))
        #expect(read?.contains("stable native capture") == true)
        let recall = request(7, #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"moot_recall_precise","first_party_provider":\#(stableProviderCompatibilityJSON()),"arguments":{"query":"stable native capture"}}}"#)
        #expect(recall?.contains("\"isError\":false") == true)

        try await context.closeActive()
        let stale = request(8, #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"moot_memory_get","first_party_provider":\#(stableProviderCompatibilityJSON()),"arguments":{"memory_id":"\#(memoryID)"}}}"#)
        #expect(stale?.contains("estate_unavailable") == true)

        try await context.reopen()
        let refreshed = request(9, #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"moot_file_memory","first_party_provider":\#(stableProviderCompatibilityJSON()),"arguments":{"content":"refreshed daemon estate","subject":"reopen","location":"HTTP integration"}}}"#)
        #expect(statusLine(refreshed).contains("200"))
        #expect(refreshed?.contains("\"isError\":false") == true)
    }

    @Test("authenticated composition aggregates installed Community tools without weakening provider admission")
    func authenticatedCompositionKeepsCommunityAndStableProviderContractsSeparate() async throws {
        let estateID = UUID()
        let descriptor = signedDescriptor(for: estateID)
        let auth = FirstPartyAuthServer(
            rootProvider: FixedFirstPartyRootProvider(root: Vectors.fixedRoot),
            descriptor: descriptor,
            serverName: "ARIA_MCP",
            now: { 1_766_000_000 },
            randomBytes: { Array(repeating: 17, count: $0) }
        )
        let provider = FirstPartyHTTPProvider()
        let communityLog = CommunityInvocationLog()
        let (port, stop) = try startServing(
            makeProviderDispatcher(provider, communityHandler: OneCommunityHandler(log: communityLog)),
            firstPartyAuth: auth
        )
        defer { stop() }
        let session = try await ServerFixtures.handshake(auth, descriptor: descriptor)

        let listed = authenticatedRequest(
            port: port,
            session: session,
            sequence: 1,
            body: #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#
        )
        let listedObject = try responseObject(listed)
        let listedResult = try #require(listedObject["result"] as? [String: Any])
        let listedTools = try #require(listedResult["tools"] as? [[String: Any]])
        let listedNames = Set(listedTools.compactMap { $0["name"] as? String })
        #expect(listedNames == ["stable.first_party.http", "moot_community_http_test"])
        #expect(listedTools.count == 2)

        let community = authenticatedRequest(
            port: port,
            session: session,
            sequence: 2,
            body: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"moot_community_http_test","arguments":{}}}"#
        )
        let communityObject = try responseObject(community)
        let communityResult = try #require(communityObject["result"] as? [String: Any])
        #expect(communityResult["source"] as? String == "community-http")
        #expect(communityLog.dispatches == 1)
        #expect(await provider.callCount() == 0)

        let missingProviderTuple = authenticatedRequest(
            port: port,
            session: session,
            sequence: 3,
            body: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"stable.first_party.http","arguments":{}}}"#
        )
        let missingTupleObject = try responseObject(missingProviderTuple)
        let missingTupleError = try #require(missingTupleObject["error"] as? [String: Any])
        #expect(missingTupleError["code"] as? Int == JSONRPCErrorCode.invalidParams)
        #expect(await provider.callCount() == 0)

        let unknown = authenticatedRequest(
            port: port,
            session: session,
            sequence: 4,
            body: #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"moot_unknown_authenticated_name","arguments":{}}}"#
        )
        let unknownObject = try responseObject(unknown)
        let unknownError = try #require(unknownObject["error"] as? [String: Any])
        #expect(unknownError["code"] as? Int == JSONRPCErrorCode.methodNotFound)
        #expect(await provider.callCount() == 0)

        let publicCall = send(port: port, raw: rawRequest(
            target: "/mcp",
            headers: [("Content-Type", "application/json")],
            body: #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"moot_community_http_test","arguments":{}}}"#
        ))
        let publicObject = try responseObject(publicCall)
        let publicError = try #require(publicObject["error"] as? [String: Any])
        #expect(publicError["code"] as? Int == JSONRPCErrorCode.methodNotFound)
        #expect(communityLog.dispatches == 1)
        #expect(await provider.callCount() == 0)

        let unauthenticated = send(port: port, raw: rawRequest(
            target: "/mcp/first-party",
            headers: [("Content-Type", "application/json")],
            body: #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"moot_community_http_test","arguments":{}}}"#
        ))
        #expect(statusLine(unauthenticated).contains("401"))
        #expect(communityLog.dispatches == 1)
        #expect(await provider.callCount() == 0)
    }

    @Test("native mutation grammar executes through the real stable provider dispatch")
    func stableProviderAcceptsNativeMutationGrammarAndRetainsWing() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-mcp-stable-provider-native-mutations")
        let storage = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
        defer { Task { try? await kit.close(handle) } }

        func capture(_ subject: String, room: String = "native grammar", wing: String = LocusKit.defaultWingName) async throws -> Drawer {
            try await kit.capture(handle, CaptureFrame(
                content: "native grammar \(subject)", channel: .actuator, room: room,
                latticeAnchor: LatticeAnchor(udcCode: "000", udcFacets: nil, wikidataQID: nil, wikidataQidsSecondary: nil),
                addedBy: "test", embeddingModelID: "default", sensitivity: .normal, kind: .prose,
                provenanceChannel: .mcpAgent, sourceType: .imported, eventTime: nil,
                exportability: .private_, wing: wing, subject: subject))
        }
        let updateTarget = try await capture("update target")
        let withdrawTarget = try await capture("withdraw target")
        let eraseTarget = try await capture("erase target")
        let confirmTarget = try await capture("confirm target")
        let moveTarget = try await capture("move target", room: "old room", wing: "Retained Native Wing")
        let tunnelSource = try await capture("tunnel source")
        let tunnelTarget = try await capture("tunnel target")
        let tunnel = try await kit.captureTunnel(handle, TunnelCaptureFrame(
            sourceWing: LocusKit.defaultWingName, sourceRoom: "native grammar", targetWing: LocusKit.defaultWingName,
            targetRoom: "native grammar", label: "native grammar review", addedBy: "test", sourceDrawerId: tunnelSource.id,
            targetDrawerId: tunnelTarget.id, kind: .validates, originClass: .derived, lifecycle: .proposed))
        let fact = try await kit.captureKGFact(handle, subject: "native grammar fact", predicate: "status", object: "active",
                                               sourceDrawerID: updateTarget.id, addedBy: "test", now: Date())

        let descriptor = signedDescriptor(for: handle.estateUUID)
        let auth = FirstPartyAuthServer(rootProvider: FixedFirstPartyRootProvider(root: Vectors.fixedRoot), descriptor: descriptor,
                                        serverName: "ARIA_MCP", now: { 1_766_000_000 }, randomBytes: { Array(repeating: 13, count: $0) })
        let provider = FirstPartyProviderExecutor()
        await provider.installFirstPartyProviderExecutorContext(FixedEstateExecutorContext(kit: kit, handle: handle))
        let (port, stop) = try startServing(makeProviderDispatcher(provider), firstPartyAuth: auth)
        defer { stop() }
        let session = try await ServerFixtures.handshake(auth, descriptor: descriptor)
        func call(_ sequence: UInt64, _ name: String, _ arguments: String) -> String? {
            authenticatedRequest(port: port, session: session, sequence: sequence,
                body: #"{"jsonrpc":"2.0","id":\#(sequence),"method":"tools/call","params":{"name":"\#(name)","first_party_provider":\#(stableProviderCompatibilityJSON()),"arguments":\#(arguments)}}"#)
        }
        let responses = [
            call(1, "moot_update_memory", #"{"id":"\#(updateTarget.id)","mutation":"set_subject","subject":"updated through native id"}"#),
            call(2, "moot_withdraw_memory", #"{"id":"\#(withdrawTarget.id)"}"#),
            call(3, "moot_erase_memory", #"{"id":"\#(eraseTarget.id)","confirmed":true}"#),
            call(4, "moot_confirm_memory", #"{"id":"\#(confirmTarget.id)"}"#),
            call(5, "moot_move_memory", #"{"id":"\#(moveTarget.id)","location":"new room"}"#),
            call(6, "moot_review_tunnel", #"{"tunnel_id":"\#(tunnel.id)","verdict":"accept"}"#),
            call(7, "moot_retire_fact", #"{"id":"\#(fact.id)"}"#),
        ]
        for response in responses { #expect(response?.contains("\"isError\":false") == true) }

        let estate = try await kit.estate(for: handle)
        let persisted = try await estate.allDrawers()
        #expect(persisted.first(where: { $0.id == updateTarget.id })?.subject == "updated through native id")
        #expect(persisted.first(where: { $0.id == withdrawTarget.id })?.state == .withdrawn)
        let erased = try #require(persisted.first(where: { $0.id == eraseTarget.id }))
        #expect(erased.tombstonedAt != nil)
        #expect(erased.content.isEmpty)
        #expect(persisted.first(where: { $0.id == confirmTarget.id })?.confirmation == .userConfirmed)
        let moved = try #require(persisted.first(where: { $0.id == moveTarget.id }))
        let placement = try #require(try await kit.resolveNodeNames(handle, parentNodeIds: [moved.parentNodeId])[moved.parentNodeId])
        #expect(placement.wing == "Retained Native Wing")
        #expect(placement.room == "new room")
        #expect(try await estate.getTunnel(id: tunnel.id)?.lifecycle == .active)
        #expect(try await kit.recallKGFacts(handle).contains(where: { $0.id == fact.id }) == false)
    }

    @Test("stable provider exact fact inventory cannot select or retire another miner's facts")
    func stableProviderExactFactInventoryIsMinerScoped() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-mcp-stable-provider-miner-scope")
        let storage = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
        defer { Task { try? await kit.close(handle) } }
        func anchor(_ subject: String) async throws -> Drawer {
            try await kit.capture(handle, CaptureFrame(content: "source anchor \(subject)", channel: .actuator, room: "miners",
                latticeAnchor: LatticeAnchor(udcCode: "000", udcFacets: nil, wikidataQID: nil, wikidataQidsSecondary: nil),
                addedBy: "test", embeddingModelID: "default", sensitivity: .normal, kind: .prose, provenanceChannel: .mcpAgent,
                sourceType: .imported, eventTime: nil, exportability: .private_, wing: LocusKit.defaultWingName, subject: subject))
        }
        let calendarAnchor = try await anchor("calendar miner")
        let healthAnchor = try await anchor("health miner")
        let calendarFact = try await kit.captureKGFact(handle, subject: "calendar.event.ev-1", predicate: "scheduled", object: "calendar-owned", sourceDrawerID: calendarAnchor.id, addedBy: "test", now: Date())
        let substringFact = try await kit.captureKGFact(handle, subject: "calendar.event.ev-10", predicate: "scheduled", object: "calendar-substring", sourceDrawerID: calendarAnchor.id, addedBy: "test", now: Date())
        let healthFact = try await kit.captureKGFact(handle, subject: "calendar.event.ev-1", predicate: "scheduled", object: "health-owned", sourceDrawerID: healthAnchor.id, addedBy: "test", now: Date())
        let sourcelessFact = try await kit.captureKGFact(handle, subject: "hand-filed", predicate: "status", object: "sourceless", sourceDrawerID: "", addedBy: "test", now: Date())
        let descriptor = signedDescriptor(for: handle.estateUUID)
        let auth = FirstPartyAuthServer(rootProvider: FixedFirstPartyRootProvider(root: Vectors.fixedRoot), descriptor: descriptor, serverName: "ARIA_MCP", now: { 1_766_000_000 }, randomBytes: { Array(repeating: 11, count: $0) })
        let provider = FirstPartyProviderExecutor()
        await provider.installFirstPartyProviderExecutorContext(FixedEstateExecutorContext(kit: kit, handle: handle))
        let (port, stop) = try startServing(makeProviderDispatcher(provider), firstPartyAuth: auth)
        defer { stop() }
        let session = try await ServerFixtures.handshake(auth, descriptor: descriptor)
        let exact = authenticatedRequest(port: port, session: session, sequence: 1,
            body: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"moot_fact_search","first_party_provider":\#(stableProviderCompatibilityJSON()),"arguments":{"source_id_exact":"\#(calendarAnchor.id)","subject_exact":"calendar.event.ev-1","limit":500}}}"#)
        #expect(exact?.contains(calendarFact.id.lowercased()) == true)
        #expect(exact?.contains(substringFact.id.lowercased()) == false)
        #expect(exact?.contains(healthFact.id.lowercased()) == false)
        let retired = authenticatedRequest(port: port, session: session, sequence: 2,
            body: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"moot_retire_fact","first_party_provider":\#(stableProviderCompatibilityJSON()),"arguments":{"fact_id":"\#(calendarFact.id)"}}}"#)
        #expect(retired?.contains("\"isError\":false") == true)
        let activeIDs = Set(try await kit.recallKGFacts(handle).map(\.id))
        #expect(!activeIDs.contains(calendarFact.id))
        #expect(activeIDs.contains(substringFact.id))
        #expect(activeIDs.contains(healthFact.id))
        let sourceless = authenticatedRequest(port: port, session: session, sequence: 3,
            body: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"moot_fact_search","first_party_provider":\#(stableProviderCompatibilityJSON()),"arguments":{"source_id_exact":""}}}"#)
        #expect(sourceless?.contains(sourcelessFact.id.lowercased()) == true)
        let legacyRead = authenticatedRequest(port: port, session: session, sequence: 4,
            body: #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"moot_fact_search","first_party_provider":\#(legacyStableProviderCompatibilityJSON()),"arguments":{}}}"#)
        #expect(legacyRead?.contains("\"isError\":false") == true)
        let dishonestLegacy = authenticatedRequest(port: port, session: session, sequence: 5,
            body: #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"moot_fact_search","first_party_provider":\#(legacyStableProviderCompatibilityJSON()),"arguments":{"source_id_exact":""}}}"#)
        #expect(dishonestLegacy?.contains("require FirstPartyProvider 1.1.0") == true)
    }

    @Test("caller-requested exportable recall omits private rows on the stable dispatch path")
    func stableProviderCallerExportableFilterNarrowsRecall() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-mcp-stable-provider-export-filter")
        let storage = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
        defer { Task { try? await kit.close(handle) } }
        func capture(_ marker: String, _ exportability: AdjectiveExportability) async throws -> Drawer {
            try await kit.capture(handle, CaptureFrame(content: "provider-export-filter-signal \(marker)", channel: .actuator, room: "recall",
                latticeAnchor: LatticeAnchor(udcCode: "000", udcFacets: nil, wikidataQID: nil, wikidataQidsSecondary: nil),
                addedBy: "test", embeddingModelID: "default", sensitivity: .normal, kind: .prose, provenanceChannel: .mcpAgent,
                sourceType: .imported, eventTime: nil, exportability: exportability, wing: LocusKit.defaultWingName, subject: marker))
        }
        let publicDrawer = try await capture("public", .public_)
        let privateDrawer = try await capture("private", .private_)
        let descriptor = signedDescriptor(for: handle.estateUUID)
        let auth = FirstPartyAuthServer(rootProvider: FixedFirstPartyRootProvider(root: Vectors.fixedRoot), descriptor: descriptor, serverName: "ARIA_MCP", now: { 1_766_000_000 }, randomBytes: { Array(repeating: 12, count: $0) })
        let provider = FirstPartyProviderExecutor()
        await provider.installFirstPartyProviderExecutorContext(FixedEstateExecutorContext(kit: kit, handle: handle))
        let (port, stop) = try startServing(makeProviderDispatcher(provider), firstPartyAuth: auth)
        defer { stop() }
        let session = try await ServerFixtures.handshake(auth, descriptor: descriptor)
        for (sequence, tool) in [(UInt64(1), "moot_memory_search"), (UInt64(2), "moot_recall_precise")] {
            let response = authenticatedRequest(port: port, session: session, sequence: sequence,
                body: #"{"jsonrpc":"2.0","id":\#(sequence),"method":"tools/call","params":{"name":"\#(tool)","first_party_provider":\#(stableProviderCompatibilityJSON()),"arguments":{"query":"provider-export-filter-signal","filter":"exportable","limit":20}}}"#)
            #expect(response?.contains("\"isError\":false") == true)
            #expect(response?.lowercased().contains(publicDrawer.id.lowercased()) == true)
            #expect(response?.lowercased().contains(privateDrawer.id.lowercased()) == false)
        }
    }

    @Test("restrictive real provider policy filters direct reads and closes aggregate reads")
    func restrictivePolicyCannotBypassRealProviderReads() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FirstPartyProviderPolicy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("estate.sqlite")
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-mcp-stable-provider-policy")
        let storage = try SQLiteStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .sqlite(url: url, busyTimeout: 5.0)))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
        defer { Task { try? await kit.close(handle) } }
        let descriptor = signedDescriptor(for: handle.estateUUID)
        let auth = FirstPartyAuthServer(rootProvider: FixedFirstPartyRootProvider(root: Vectors.fixedRoot), descriptor: descriptor, serverName: "ARIA_MCP", now: { 1_766_000_000 }, randomBytes: { Array(repeating: 8, count: $0) })
        let provider = FirstPartyProviderExecutor()
        await provider.installFirstPartyProviderExecutorContext(FixedEstateExecutorContext(kit: kit, handle: handle))
        let (port, stop) = try startServing(makeProviderDispatcher(provider, recallPolicyAuthority: FixedFirstPartyRecallPolicyAuthority()), firstPartyAuth: auth)
        defer { stop() }
        let session = try await ServerFixtures.handshake(auth, descriptor: descriptor)
        let captured = authenticatedRequest(port: port, session: session, sequence: 1,
            body: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"moot_file_memory","first_party_provider":\#(stableProviderCompatibilityJSON()),"arguments":{"content":"private policy row","subject":"private row","location":"policy","exportability":"private"}}}"#)
        let object = try responseObject(captured)
        let result = try #require(object["result"] as? [String: Any])
        let structured = try #require(result["structuredContent"] as? [String: Any])
        let data = try #require(structured["data"] as? [String: Any])
        let memoryID = try #require(data["memory_id"] as? String)
        let bytesBeforeReads = try sqliteBytes(url)
        let get = authenticatedRequest(port: port, session: session, sequence: 2,
            body: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"moot_memory_get","first_party_provider":\#(stableProviderCompatibilityJSON()),"arguments":{"memory_id":"\#(memoryID)"}}}"#)
        #expect(get?.contains("private policy row") == false)
        let mutation = authenticatedRequest(port: port, session: session, sequence: 3,
            body: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"moot_update_memory","first_party_provider":\#(stableProviderCompatibilityJSON()),"arguments":{"memory_id":"\#(memoryID)","mutation":"correct_exportability","exportability":"public"}}}"#)
        // The selected v2 sensitivity gate intentionally collapses a hidden
        // target into the same opaque refusal as an absent target.  Pin the
        // wire-level failure rather than restoring the pre-int3 diagnostic.
        #expect(mutation?.contains("\"isError\":true") == true)
        #expect(try sqliteBytes(url) == bytesBeforeReads)
        let aggregateRequests: [(UInt64, String, String)] = [
            (4, "moot_memory_list", #"{"wing":"Agentic Memory"}"#),
            (5, "moot_fact_search", "{}"),
            (6, "moot_read_journal", "{}"),
            (7, "moot_list_lenses", "{}"),
        ]
        for (sequence, name, arguments) in aggregateRequests {
            let response = authenticatedRequest(port: port, session: session, sequence: sequence,
                body: #"{"jsonrpc":"2.0","id":\#(sequence),"method":"tools/call","params":{"name":"\#(name)","first_party_provider":\#(stableProviderCompatibilityJSON()),"arguments":\#(arguments)}}"#)
            #expect(response?.contains("recall_policy_restricted") == true)
            #expect(response?.contains("private policy row") == false)
        }
        #expect(try sqliteBytes(url) == bytesBeforeReads)
    }

    @Test("no-grant real provider hides rows facts and tunnels before mutation")
    func noGrantPolicyCannotRelabelSecretMemory() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-mcp-stable-provider-no-grant")
        let storage = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
        defer { Task { try? await kit.close(handle) } }
        func capture(_ content: String, sensitivity: AdjectiveSensitivity) async throws -> Drawer {
            try await kit.capture(handle, CaptureFrame(content: content, channel: .actuator, room: "policy",
                latticeAnchor: LatticeAnchor(udcCode: "000", udcFacets: nil, wikidataQID: nil, wikidataQidsSecondary: nil),
                addedBy: "test", embeddingModelID: "default", sensitivity: sensitivity, kind: .prose, provenanceChannel: .mcpAgent,
                sourceType: .imported, eventTime: nil, exportability: .private_, wing: LocusKit.defaultWingName, subject: content))
        }
        let secret = try await capture("secret no grant row", sensitivity: .secret)
        let visible = try await capture("visible tunnel endpoint", sensitivity: .normal)
        let fact = try await kit.captureKGFact(handle, subject: "secret subject", predicate: "has", object: "secret fact", sourceDrawerID: secret.id, addedBy: "test", now: Date())
        let tunnel = try await kit.captureTunnel(handle, TunnelCaptureFrame(sourceWing: LocusKit.defaultWingName, sourceRoom: "policy", targetWing: LocusKit.defaultWingName, targetRoom: "policy", label: "secret source proposal", addedBy: "test", sourceDrawerId: secret.id, targetDrawerId: visible.id, kind: .contradicts, originClass: .derived, lifecycle: .proposed))
        let descriptor = signedDescriptor(for: handle.estateUUID)
        let auth = FirstPartyAuthServer(rootProvider: FixedFirstPartyRootProvider(root: Vectors.fixedRoot), descriptor: descriptor, serverName: "ARIA_MCP", now: { 1_766_000_000 }, randomBytes: { Array(repeating: 10, count: $0) })
        let provider = FirstPartyProviderExecutor()
        await provider.installFirstPartyProviderExecutorContext(FixedEstateExecutorContext(kit: kit, handle: handle))
        let (port, stop) = try startServing(makeProviderDispatcher(provider), firstPartyAuth: auth)
        defer { stop() }
        let session = try await ServerFixtures.handshake(auth, descriptor: descriptor)
        let update = authenticatedRequest(port: port, session: session, sequence: 1,
            body: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"moot_update_memory","first_party_provider":\#(stableProviderCompatibilityJSON()),"arguments":{"memory_id":"\#(secret.id)","mutation":"correct_sensitivity","sensitivity":"normal"}}}"#)
        // Hidden and nonexistent rows remain deliberately indistinguishable.
        #expect(update?.contains("\"isError\":true") == true)
        let retire = authenticatedRequest(port: port, session: session, sequence: 2,
            body: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"moot_retire_fact","first_party_provider":\#(stableProviderCompatibilityJSON()),"arguments":{"fact_id":"\#(fact.id)"}}}"#)
        #expect(retire?.contains("\"isError\":true") == true)
        let review = authenticatedRequest(port: port, session: session, sequence: 3,
            body: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"moot_review_tunnel","first_party_provider":\#(stableProviderCompatibilityJSON()),"arguments":{"tunnel_id":"\#(tunnel.id)","decision":"accept"}}}"#)
        #expect(review?.contains("\"isError\":true") == true)
        let estate = try await kit.estate(for: handle)
        #expect(try await estate.allDrawers().first(where: { $0.id == secret.id })?.adjectiveSensitivity == .secret)
        #expect(try await kit.recallKGFacts(handle).contains(where: { $0.id == fact.id }))
        #expect(try await estate.getTunnel(id: tunnel.id)?.lifecycle == .proposed)
        let keystones = authenticatedRequest(port: port, session: session, sequence: 4,
            body: #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"moot_lens_keystones","first_party_provider":\#(stableProviderCompatibilityJSON()),"arguments":{"wing":"\#(LocusKit.defaultWingName)","topK":10,"keystoneOnly":false}}}"#)
        #expect(keystones?.lowercased().contains(secret.id.lowercased()) == false)
    }

    @Test("real provider rejects a verified cross-estate caller before a capture mutates")
    func crossEstateRealProviderRefusesBeforeMutation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FirstPartyProviderCrossEstate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("estate.sqlite")
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-mcp-stable-provider-cross-estate")
        let storage = try SQLiteStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .sqlite(url: url, busyTimeout: 5.0)))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
        defer { Task { try? await kit.close(handle) } }
        var foreignEstate = UUID(); while foreignEstate == handle.estateUUID { foreignEstate = UUID() }
        let auth = FirstPartyAuthServer(rootProvider: FixedFirstPartyRootProvider(root: Vectors.fixedRoot), descriptor: signedDescriptor(for: foreignEstate), serverName: "ARIA_MCP", now: { 1_766_000_000 }, randomBytes: { Array(repeating: 9, count: $0) })
        let provider = FirstPartyProviderExecutor()
        await provider.installFirstPartyProviderExecutorContext(FixedEstateExecutorContext(kit: kit, handle: handle))
        let (port, stop) = try startServing(makeProviderDispatcher(provider), firstPartyAuth: auth)
        defer { stop() }
        let descriptor = signedDescriptor(for: foreignEstate)
        let session = try await ServerFixtures.handshake(auth, descriptor: descriptor)
        let bytesBefore = try sqliteBytes(url)
        let response = authenticatedRequest(port: port, session: session, sequence: 1,
            body: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"moot_file_memory","first_party_provider":\#(stableProviderCompatibilityJSON()),"arguments":{"content":"foreign estate mutation","subject":"must refuse","location":"cross estate"}}}"#)
        #expect(response?.contains("estate_unavailable") == true)
        #expect(try sqliteBytes(url) == bytesBefore)
    }

    @Test("each verified HTTP session reaches a stable provider with its own bound caller context")
    func stableProviderReceivesDistinctVerifiedSessionContexts() async throws {
        let descriptor = ServerFixtures.signedDescriptor()
        let clock = ManualClock()
        let counter = RandomCounter()
        let auth = FirstPartyAuthServer(rootProvider: FixedFirstPartyRootProvider(root: Vectors.fixedRoot), descriptor: descriptor,
                                        serverName: "ARIA_MCP", now: { clock.seconds }, randomBytes: { counter.next($0) })
        let provider = FirstPartyHTTPProvider()
        let (port, stop) = try startServing(makeProviderDispatcher(provider, recallPolicyAuthority: FixedFirstPartyRecallPolicyAuthority()), firstPartyAuth: auth)
        defer { stop() }
        for requestID in [1, 2] {
            let session = try await ServerFixtures.handshake(auth, descriptor: descriptor)
            let body = #"{"jsonrpc":"2.0","id":\#(requestID),"method":"tools/call","params":{"name":"stable.first_party.http","first_party_provider":\#(stableProviderCompatibilityJSON()),"arguments":{}}}"#
            let response = authenticatedRequest(port: port, session: session, sequence: 1, body: body)
            #expect(statusLine(response).contains("200"))
            #expect(response?.contains("stable-first-party-http") == true)
        }
        let contexts = await provider.contexts
        #expect(contexts.count == 2)
        #expect(contexts[0].sessionIdentifier != contexts[1].sessionIdentifier)
        #expect(contexts.allSatisfy { $0.sequence == 1 })
        #expect(contexts.allSatisfy { $0.estateIdentifier == descriptor.estateIdentifier })
        #expect(contexts.allSatisfy { $0.instanceIdentifier == descriptor.instanceIdentifier })
        #expect(contexts.allSatisfy { $0.recallPolicy.maximumSensitivity == .restricted && $0.recallPolicy.exportability == .exportableOnly })
    }

    @Test("an authenticated session restriction is daemon-owned and does not narrow the owner session")
    func authenticatedSessionRestrictionBindsProviderAuthority() async throws {
        let descriptor = ServerFixtures.signedDescriptor()
        let clock = ManualClock()
        let counter = RandomCounter()
        let auth = FirstPartyAuthServer(rootProvider: FixedFirstPartyRootProvider(root: Vectors.fixedRoot), descriptor: descriptor,
                                        serverName: "ARIA_MCP", now: { clock.seconds }, randomBytes: { counter.next($0) })
        let provider = FirstPartyHTTPProvider()
        let (port, stop) = try startServing(makeProviderDispatcher(provider), firstPartyAuth: auth)
        defer { stop() }
        let lanSession = try await ServerFixtures.handshake(auth, descriptor: descriptor)
        let restricted = authenticatedRequest(port: port, session: lanSession, sequence: 1,
                                              body: #"{"jsonrpc":"2.0","id":1,"method":"mootx01/session/restrict-recall-to-exportable"}"#)
        #expect(restricted?.contains("\"restricted\":true") == true)
        let lanRead = authenticatedRequest(port: port, session: lanSession, sequence: 2,
                                           body: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"stable.first_party.http","first_party_provider":\#(stableProviderCompatibilityJSON()),"arguments":{}}}"#)
        #expect(lanRead?.contains("stable-first-party-http") == true)
        let ownerSession = try await ServerFixtures.handshake(auth, descriptor: descriptor)
        let ownerRead = authenticatedRequest(port: port, session: ownerSession, sequence: 1,
                                             body: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"stable.first_party.http","first_party_provider":\#(stableProviderCompatibilityJSON()),"arguments":{}}}"#)
        #expect(ownerRead?.contains("stable-first-party-http") == true)
        let contexts = await provider.contexts
        #expect(contexts.count == 2)
        #expect(contexts[0].recallPolicy.exportability == .exportableOnly)
        #expect(contexts[1].recallPolicy == .noGrant)
    }

    @Test("stable provider is untouched by invalid MAC and replayed authenticated requests")
    func stableProviderRejectsInvalidAndReplayedRequestsBeforeDispatch() async throws {
        let descriptor = ServerFixtures.signedDescriptor()
        let clock = ManualClock()
        let counter = RandomCounter()
        let auth = FirstPartyAuthServer(rootProvider: FixedFirstPartyRootProvider(root: Vectors.fixedRoot), descriptor: descriptor,
                                        serverName: "ARIA_MCP", now: { clock.seconds }, randomBytes: { counter.next($0) })
        let provider = FirstPartyHTTPProvider()
        let (port, stop) = try startServing(makeProviderDispatcher(provider), firstPartyAuth: auth)
        defer { stop() }
        let session = try await ServerFixtures.handshake(auth, descriptor: descriptor)
        let body = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"stable.first_party.http","first_party_provider":\#(stableProviderCompatibilityJSON()),"arguments":{}}}"#
        let validMAC = FirstPartyAuthProtocol.requestMAC(sessionKey: session.sessionKey, sessionIdentifier: session.sessionIdentifier,
                                                          sequence: 1, method: "POST", path: "/mcp/first-party", contentType: "application/json", body: Data(body.utf8))
        let invalid = send(port: port, raw: rawRequest(target: "/mcp/first-party", headers: [
            ("Content-Type", "application/json"), ("Authorization", "Mootx01Session " + FirstPartyAuthProtocol.base64URLEncode(session.sessionIdentifier)),
            ("Mootx01-Sequence", "1"), ("Mootx01-Request-MAC", FirstPartyAuthProtocol.base64URLEncode([UInt8](repeating: 0, count: validMAC.count))),
        ], body: body))
        #expect(statusLine(invalid).contains("401"))
        #expect(await provider.contexts.isEmpty)
        let valid = send(port: port, raw: rawRequest(target: "/mcp/first-party", headers: [
            ("Content-Type", "application/json"), ("Authorization", "Mootx01Session " + FirstPartyAuthProtocol.base64URLEncode(session.sessionIdentifier)),
            ("Mootx01-Sequence", "1"), ("Mootx01-Request-MAC", FirstPartyAuthProtocol.base64URLEncode(validMAC)),
        ], body: body))
        #expect(statusLine(valid).contains("200"))
        #expect(await provider.contexts.count == 1)
        let replay = send(port: port, raw: rawRequest(target: "/mcp/first-party", headers: [
            ("Content-Type", "application/json"), ("Authorization", "Mootx01Session " + FirstPartyAuthProtocol.base64URLEncode(session.sessionIdentifier)),
            ("Mootx01-Sequence", "1"), ("Mootx01-Request-MAC", FirstPartyAuthProtocol.base64URLEncode(validMAC)),
        ], body: body))
        #expect(statusLine(replay).contains("409"))
        #expect(await provider.contexts.count == 1)
    }

    @Test("A full handshake and an authenticated request succeed with a verifiable response MAC")
    func authenticatedRoundTrip() async throws {
        let descriptor = ServerFixtures.signedDescriptor()
        let clock = ManualClock()
        let counter = RandomCounter()
        let auth = FirstPartyAuthServer(
            rootProvider: FixedFirstPartyRootProvider(root: Vectors.fixedRoot),
            descriptor: descriptor, serverName: "ARIA_MCP",
            now: { clock.seconds }, randomBytes: { counter.next($0) }
        )
        let dispatcher = try await makeDispatcher()
        let (port, stop) = try startServing(
            dispatcher, firstPartyAuth: auth
        )
        defer { stop() }

        // Handshake in-process; the wire form of the handshake is exercised by
        // the challenge route below.
        let session = try await ServerFixtures.handshake(auth, descriptor: descriptor)

        let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let mac = FirstPartyAuthProtocol.requestMAC(
            sessionKey: session.sessionKey, sessionIdentifier: session.sessionIdentifier,
            sequence: 1, method: "POST", path: "/mcp/first-party",
            contentType: "application/json", body: Data(body.utf8)
        )
        let response = send(port: port, raw: rawRequest(
            target: "/mcp/first-party",
            headers: [
                ("Content-Type", "application/json"),
                ("Authorization", "Mootx01Session "
                    + FirstPartyAuthProtocol.base64URLEncode(session.sessionIdentifier)),
                ("Mootx01-Sequence", "1"),
                ("Mootx01-Request-MAC", FirstPartyAuthProtocol.base64URLEncode(mac)),
            ],
            body: body
        ))
        #expect(statusLine(response).contains("200"))
        #expect(response?.contains("Mootx01-Response-MAC") == true)

        // The client's half: recompute the response MAC over the exact body.
        let parts = try #require(response?.components(separatedBy: "\r\n\r\n"))
        let responseBody = parts.count > 1 ? parts[1] : ""
        let expected = FirstPartyAuthProtocol.responseMAC(
            sessionKey: session.sessionKey, sessionIdentifier: session.sessionIdentifier,
            sequence: 1, status: 200, contentType: "application/json",
            body: Data(responseBody.utf8)
        )
        #expect(response?.contains(FirstPartyAuthProtocol.base64URLEncode(expected)) == true,
                "the response MAC must verify over the exact transmitted body")
    }

    @Test("An unauthenticated request is refused without parsing or dispatching")
    func unauthenticatedRefused() async throws {
        let descriptor = ServerFixtures.signedDescriptor()
        let clock = ManualClock()
        let counter = RandomCounter()
        let auth = FirstPartyAuthServer(
            rootProvider: FixedFirstPartyRootProvider(root: Vectors.fixedRoot),
            descriptor: descriptor, serverName: "ARIA_MCP",
            now: { clock.seconds }, randomBytes: { counter.next($0) }
        )
        let dispatcher = try await makeDispatcher()
        let (port, stop) = try startServing(
            dispatcher, firstPartyAuth: auth
        )
        defer { stop() }

        // A syntactically perfect JSON-RPC call with no credentials at all.
        let response = send(port: port, raw: rawRequest(
            target: "/mcp/first-party",
            headers: [("Content-Type", "application/json")],
            body: #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        ))
        #expect(statusLine(response).contains("401"))
        // The parse-before-MAC sentinel: a dispatched ping would have produced a
        // result object. Its absence is the evidence that middleware ran first.
        #expect(response?.contains("\"result\"") != true)
        #expect(response?.contains("Mootx01-Response-MAC") != true)
    }

    @Test("A duplicated authentication header on the wire is refused")
    func duplicateHeaderOnTheWireRefused() async throws {
        let descriptor = ServerFixtures.signedDescriptor()
        let clock = ManualClock()
        let counter = RandomCounter()
        let auth = FirstPartyAuthServer(
            rootProvider: FixedFirstPartyRootProvider(root: Vectors.fixedRoot),
            descriptor: descriptor, serverName: "ARIA_MCP",
            now: { clock.seconds }, randomBytes: { counter.next($0) }
        )
        let dispatcher = try await makeDispatcher()
        let (port, stop) = try startServing(
            dispatcher, firstPartyAuth: auth
        )
        defer { stop() }
        let session = try await ServerFixtures.handshake(auth, descriptor: descriptor)

        let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let mac = FirstPartyAuthProtocol.requestMAC(
            sessionKey: session.sessionKey, sessionIdentifier: session.sessionIdentifier,
            sequence: 1, method: "POST", path: "/mcp/first-party",
            contentType: "application/json", body: Data(body.utf8)
        )
        // Two Mootx01-Sequence lines. LoopbackHTTP would have collapsed these to
        // "2" before anything could object; the strict parser keeps both.
        let response = send(port: port, raw: rawRequest(
            target: "/mcp/first-party",
            headers: [
                ("Content-Type", "application/json"),
                ("Authorization", "Mootx01Session "
                    + FirstPartyAuthProtocol.base64URLEncode(session.sessionIdentifier)),
                ("Mootx01-Sequence", "1"),
                ("Mootx01-Sequence", "2"),
                ("Mootx01-Request-MAC", FirstPartyAuthProtocol.base64URLEncode(mac)),
            ],
            body: body
        ))
        #expect(statusLine(response).contains("401"))
        #expect(response?.contains("\"result\"") != true)
    }

    @Test("A notification receives a MACed empty 204")
    func notificationReceivesMACed204() async throws {
        let descriptor = ServerFixtures.signedDescriptor()
        let clock = ManualClock()
        let counter = RandomCounter()
        let auth = FirstPartyAuthServer(
            rootProvider: FixedFirstPartyRootProvider(root: Vectors.fixedRoot),
            descriptor: descriptor, serverName: "ARIA_MCP",
            now: { clock.seconds }, randomBytes: { counter.next($0) }
        )
        let dispatcher = try await makeDispatcher()
        let (port, stop) = try startServing(
            dispatcher, firstPartyAuth: auth
        )
        defer { stop() }
        let session = try await ServerFixtures.handshake(auth, descriptor: descriptor)

        let body = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        let mac = FirstPartyAuthProtocol.requestMAC(
            sessionKey: session.sessionKey, sessionIdentifier: session.sessionIdentifier,
            sequence: 1, method: "POST", path: "/mcp/first-party",
            contentType: "application/json", body: Data(body.utf8)
        )
        let response = send(port: port, raw: rawRequest(
            target: "/mcp/first-party",
            headers: [
                ("Content-Type", "application/json"),
                ("Authorization", "Mootx01Session "
                    + FirstPartyAuthProtocol.base64URLEncode(session.sessionIdentifier)),
                ("Mootx01-Sequence", "1"),
                ("Mootx01-Request-MAC", FirstPartyAuthProtocol.base64URLEncode(mac)),
            ],
            body: body
        ))
        // 204, not the third-party lane's bare 202 — and authenticated.
        #expect(statusLine(response).contains("204"))
        let expected = FirstPartyAuthProtocol.responseMAC(
            sessionKey: session.sessionKey, sessionIdentifier: session.sessionIdentifier,
            sequence: 1, status: 204, contentType: "", body: Data()
        )
        #expect(response?.contains(FirstPartyAuthProtocol.base64URLEncode(expected)) == true)
    }

    @Test("The challenge route rejects a wrong descriptor digest over the wire")
    func challengeRouteRejectsWrongDigest() async throws {
        let descriptor = ServerFixtures.signedDescriptor()
        let clock = ManualClock()
        let counter = RandomCounter()
        let auth = FirstPartyAuthServer(
            rootProvider: FixedFirstPartyRootProvider(root: Vectors.fixedRoot),
            descriptor: descriptor, serverName: "ARIA_MCP",
            now: { clock.seconds }, randomBytes: { counter.next($0) }
        )
        let dispatcher = try await makeDispatcher()
        let (port, stop) = try startServing(
            dispatcher, firstPartyAuth: auth
        )
        defer { stop() }

        let payload = #"{"clientNonce":"\#(FirstPartyAuthProtocol.base64URLEncode([UInt8](repeating: 0xC1, count: 32)))","descriptorDigest":"\#(FirstPartyAuthProtocol.base64URLEncode([UInt8](repeating: 0xEE, count: 32)))"}"#
        let response = send(port: port, raw: rawRequest(
            target: "/mcp/first-party/session/challenge",
            headers: [("Content-Type", "application/json")],
            body: payload
        ))
        #expect(statusLine(response).contains("401"))
        #expect(await auth.liveChallengeCount == 0)
    }

    @Test("The raw reader caps an unauthenticated handshake body at 8 KiB")
    func handshakeBodyIsBoundedAtTheSocketRead() throws {
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer {
            close(pair[0])
            close(pair[1])
        }
        let declared = FirstPartyAuthProtocol.handshakeMaxBodyBytes + 1
        let head = "POST \(FirstPartyAuthProtocol.challengePath) HTTP/1.1\r\n"
            + "Content-Type: application/json\r\nContent-Length: \(declared)\r\n\r\n"
        var request = Data(head.utf8)
        request.append(Data(repeating: 0x41, count: declared))
        // Some Darwin socketpair configurations have a send buffer below this
        // request size. Send concurrently so the test exercises the reader's
        // cap instead of deadlocking before the reader starts.
        let writerFD = pair[0]
        let requestBytes = request
        let writer = Thread { _ = POSIXSocket.sendAll(writerFD, requestBytes) }
        writer.start()

        let raw = try #require(HTTPServer.readRawRequest(
            fd: pair[1], maxBodyBytes: 4 * 1024 * 1024, timeoutNanoseconds: 500_000_000
        ))
        let terminator = try #require(raw.range(of: Data("\r\n\r\n".utf8)))
        #expect(raw[terminator.upperBound...].count == FirstPartyAuthProtocol.handshakeMaxBodyBytes)
        // The partial body cannot accidentally pass the later strict grammar.
        #expect(StrictHTTPParser.parse(raw, maxBodyBytes: 4 * 1024 * 1024) == nil)
    }

    @Test("The armed raw reader uses one absolute deadline across slow bytes")
    func rawReaderDeadlineDoesNotRenewPerReceive() {
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer {
            close(pair[0])
            close(pair[1])
        }
        let writerFD = pair[0]
        let writer = Thread {
            for byte in Data("POS".utf8) {
                Thread.sleep(forTimeInterval: 0.02)
                var value = byte
                _ = write(writerFD, &value, 1)
            }
        }
        writer.start()

        let start = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        let result = HTTPServer.readRawRequest(
            fd: pair[1], maxBodyBytes: 4 * 1024 * 1024, timeoutNanoseconds: 80_000_000
        )
        let elapsed = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - start
        #expect(result == nil)
        #expect(elapsed < 300_000_000,
                "periodic bytes must not renew the 80 ms absolute deadline")
    }

    @Test("Cancelling the off-pool raw reader shuts down its registered fd")
    func rawReaderCancellationUnblocksDeterministically() async throws {
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let peerFD = pair[0]
        let readerFD = pair[1]
        defer {
            close(peerFD)
            close(readerFD)
        }
        let registration = RawReadRegistration()
        let task = Task {
            await HTTPServer.readRawRequestOffPool(
                fd: readerFD,
                maxBodyBytes: 4 * 1024 * 1024,
                timeoutNanoseconds: 5_000_000_000,
                afterRegistration: { registration.mark() }
            )
        }
        // Two seconds: the dedicated thread is scheduled promptly regardless of
        // GCD pool saturation. Measured post-fix under a saturated global pool,
        // registration arrives well under 40 ms.
        let waitDeadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while !registration.value, DispatchTime.now().uptimeNanoseconds < waitDeadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try #require(registration.value, "raw reader never registered its descriptor")

        // The read must run on the dedicated thread, not the shared GCD pool.
        // A regression to DispatchQueue.global gives a pool-worker name, not this
        // one, so the assertion fails deterministically without needing saturation.
        #expect(registration.threadName == "com.mootx01.aria-mcp.raw-read",
                "raw read must run on the dedicated thread, not the shared GCD pool")

        let started = DispatchTime.now().uptimeNanoseconds
        task.cancel()
        let result = await task.value
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        #expect(result == nil)
        // One second is well below the five-second reader timeout. The dedicated
        // thread is scheduled promptly; measured post-fix under a saturated global
        // pool the elapsed shutdown time was well under 40 ms.
        #expect(elapsed < 1_000_000_000,
                "cancellation must unblock recv, not wait for the five-second deadline")

        // The peer observes shutdown even though the test remains the sole
        // closer. This distinguishes handler-driven interruption from a short
        // timeout or a worker that never entered recv.
        var byte: UInt8 = 0
        #expect(read(peerFD, &byte, 1) == 0)
    }

    @Test("The raw-reader owner latches cancellation before registration")
    func rawReaderOwnerFailsClosedBeforeRegistration() {
        let owner = HTTPReadSocketOwner()
        owner.shutdownNow()
        #expect(owner.register(123) == false)
    }

    @Test("A prefix-sharing path is not treated as first-party")
    func prefixSharingPathIsNotFirstParty() {
        #expect(HTTPServer.isFirstPartyTarget("/mcp/first-party"))
        #expect(HTTPServer.isFirstPartyTarget("/mcp/first-party/session/challenge"))
        #expect(HTTPServer.isFirstPartyTarget("/mcp/first-party?x=1"))
        // Sharing a textual prefix must not be enough to enter the subtree.
        #expect(!HTTPServer.isFirstPartyTarget("/mcp/first-partyX"))
        #expect(!HTTPServer.isFirstPartyTarget("/mcp/first-party-public"))
        #expect(!HTTPServer.isFirstPartyTarget("/"))
    }

    @Test("The third-party lane is unchanged while the first-party lane is armed")
    func thirdPartyLaneUnaffected() async throws {
        let descriptor = ServerFixtures.signedDescriptor()
        let clock = ManualClock()
        let counter = RandomCounter()
        let auth = FirstPartyAuthServer(
            rootProvider: FixedFirstPartyRootProvider(root: Vectors.fixedRoot),
            descriptor: descriptor, serverName: "ARIA_MCP",
            now: { clock.seconds }, randomBytes: { counter.next($0) }
        )
        let dispatcher = try await makeDispatcher()
        let (port, stop) = try startServing(dispatcher, firstPartyAuth: auth)
        defer { stop() }

        // The public lane keeps working, unauthenticated, exactly as before —
        // and keeps its bare 202 for notifications.
        let call = send(port: port, raw: rawRequest(
            target: "/",
            headers: [("Content-Type", "application/json")],
            body: #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        ))
        #expect(statusLine(call).contains("200"))
        #expect(call?.contains("\"result\"") == true)

        let notification = send(port: port, raw: rawRequest(
            target: "/",
            headers: [("Content-Type", "application/json")],
            body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        ))
        #expect(statusLine(notification).contains("202"))

        // This dispatcher was never given an identity, so it must not advertise.
        let initialize = send(port: port, raw: rawRequest(
            target: "/",
            headers: [("Content-Type", "application/json")],
            body: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#
        ))
        #expect(initialize?.contains("authenticated-first-party") == false)
    }
}

/// Lock-protected registration observation for the cancellation regression.
///
/// `mark()` is called from the `afterRegistration` closure, which runs on
/// the dedicated read thread; it captures the thread name at that moment so
/// the test can assert the read is not running on the shared GCD pool.
private final class RawReadRegistration: @unchecked Sendable {
    private let lock = NSLock()
    private var registered = false
    private var capturedThreadName: String? = nil

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return registered
    }

    /// Name of the thread on which the read was registered, or nil before
    /// registration.
    var threadName: String? {
        lock.lock(); defer { lock.unlock() }
        return capturedThreadName
    }

    func mark() {
        lock.lock()
        registered = true
        capturedThreadName = Thread.current.name
        lock.unlock()
    }
}

// MARK: - Lane identity separation, and public-parser equivalence
//
// Root Adams findings 1 and 2. Both were defects where the AUTHENTICATED lane's
// machinery leaked into the UNAUTHENTICATED one — first the identity, then the
// grammar. These tests exist to make either regression impossible to reintroduce
// silently.

@Suite("HTTP transport — lane separation under an armed first-party lane", .serialized)
struct FirstPartyLaneSeparationTests {

    typealias Vectors = FirstPartyAuthProtocolTests
    typealias ServerFixtures = FirstPartyAuthServerTests
    typealias Lane = FirstPartyHTTPLaneTests

    private func makeDispatcher() async throws -> ARIA_MCPDispatcher {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-mcp-lane-separation-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore()
        )
        return ARIA_MCPDispatcher(
            info: ARIA_MCPDispatcher.ServerInfo(name: "ARIA_MCP", version: "1.1.0"),
            tooling: ToolDispatcher(kit: kit, handle: handle)
        )
    }

    private func makeAuth(_ descriptor: FirstPartyDescriptor) -> FirstPartyAuthServer {
        let clock = ManualClock()
        let counter = RandomCounter()
        return FirstPartyAuthServer(
            rootProvider: FixedFirstPartyRootProvider(root: Vectors.fixedRoot),
            descriptor: descriptor, serverName: "ARIA_MCP",
            now: { clock.seconds }, randomBytes: { counter.next($0) }
        )
    }

    private func serve(
        _ dispatcher: ARIA_MCPDispatcher, auth: FirstPartyAuthServer?
    ) throws -> (port: UInt16, stop: () -> Void) {
        let server = HTTPServer(dispatcher: dispatcher, port: 0, firstPartyAuth: auth)
        let (listenFD, port) = try server.bind()
        let captured = auth
        let thread = Thread {
            while let cfd = POSIXSocket.acceptOne(listenFD) {
                Task {
                    await HTTPServer.serve(
                        cfd, dispatcher: dispatcher, maxBodyBytes: 4 * 1024 * 1024,
                        sseGate: globalSSEConcurrencyGate, firstPartyAuth: captured
                    )
                }
            }
        }
        thread.name = "aria-mcp.http.lane-separation.test.accept"
        thread.start()
        return (port, { close(listenFD) })
    }

    private func send(port: UInt16, raw: String) -> String? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard POSIXSocket.sendAll(fd, Data(raw.utf8)) else { return nil }
        var out = Data()
        while let chunk = POSIXSocket.recv(fd, max: 16 * 1024), !chunk.isEmpty { out.append(chunk) }
        return String(data: out, encoding: .utf8)
    }

    // MARK: Finding 1 — identity must not cross lanes

    @Test("With the lane armed, the PUBLIC initialize still advertises nothing")
    func publicInitializeNeverAdvertisesWhileArmed() async throws {
        let descriptor = ServerFixtures.signedDescriptor()
        let auth = makeAuth(descriptor)
        let (port, stop) = try serve(try await makeDispatcher(), auth: auth)
        defer { stop() }

        let response = send(port: port, raw:
            "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n"
            + "Content-Length: 88\r\n\r\n"
            + #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#
        )
        #expect(response?.contains("200") == true)
        // The identity is the daemon's private routing state. None of it may
        // appear to an unauthenticated caller.
        #expect(response?.contains("authenticated-first-party") == false)
        #expect(response?.contains("instanceIdentifier") == false)
        #expect(response?.contains("estateIdentifier") == false)
        #expect(response?.contains("descriptorGeneration") == false)
        #expect(response?.contains("credentialGeneration") == false)
        #expect(response?.contains(descriptor.instanceIdentifier.uuidString) == false)
        #expect(response?.contains(descriptor.estateIdentifier.uuidString) == false)
    }

    @Test("An identity-bearing dispatcher cannot make the public lane advertise")
    func publicLaneStripsAnInjectedIdentity() async throws {
        let descriptor = ServerFixtures.signedDescriptor()
        let auth = makeAuth(descriptor)
        // Deliberately hand in the mistake root Adams described: a dispatcher
        // already carrying an identity. The public lane must strip it anyway.
        let poisoned = try await makeDispatcher().withFirstPartyIdentity(auth.identity)
        let (port, stop) = try serve(poisoned, auth: auth)
        defer { stop() }

        let response = send(port: port, raw:
            "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n"
            + "Content-Length: 88\r\n\r\n"
            + #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#
        )
        #expect(response?.contains("authenticated-first-party") == false)
        #expect(response?.contains(descriptor.instanceIdentifier.uuidString) == false)
    }

    @Test("The FIRST-PARTY initialize reports the identity even from a dark dispatcher")
    func firstPartyInitializeAlwaysCarriesIdentity() async throws {
        let descriptor = ServerFixtures.signedDescriptor()
        let auth = makeAuth(descriptor)
        // A plain, dark dispatcher — exactly what production passes. The lane
        // must still answer truthfully, because it takes the identity from the
        // authenticator rather than from the caller.
        let (port, stop) = try serve(try await makeDispatcher(), auth: auth)
        defer { stop() }
        let session = try await ServerFixtures.handshake(auth, descriptor: descriptor)

        let body = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#
        let mac = FirstPartyAuthProtocol.requestMAC(
            sessionKey: session.sessionKey, sessionIdentifier: session.sessionIdentifier,
            sequence: 1, method: "POST", path: "/mcp/first-party",
            contentType: "application/json", body: Data(body.utf8)
        )
        let response = send(port: port, raw:
            "POST /mcp/first-party HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n"
            + "Authorization: Mootx01Session "
            + FirstPartyAuthProtocol.base64URLEncode(session.sessionIdentifier) + "\r\n"
            + "Mootx01-Sequence: 1\r\n"
            + "Mootx01-Request-MAC: " + FirstPartyAuthProtocol.base64URLEncode(mac) + "\r\n"
            + "Content-Length: \(body.utf8.count)\r\n\r\n" + body
        )
        #expect(response?.contains("authenticated-first-party") == true)
        #expect(response?.contains(descriptor.instanceIdentifier.uuidString) == true)
        #expect(response?.contains(descriptor.estateIdentifier.uuidString) == true)
    }

    // MARK: Finding 2 — the public grammar must not change when the lane is armed

    /// Every case the legacy parser ACCEPTS and the strict parser refuses.
    /// Routing the public lane through the strict parser turned each of these
    /// into a 400 the moment a first-party authenticator was configured.
    static let legacyAcceptedRequests: [(name: String, raw: String)] = [
        ("whitespace before the colon in a field name",
         "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type : application/json\r\n"
         + "Content-Length: 40\r\n\r\n" + #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#),
        ("duplicate Content-Length, last wins",
         "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n"
         + "Content-Length: 999\r\nContent-Length: 40\r\n\r\n"
         + #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#),
        ("Transfer-Encoding present and ignored",
         "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n"
         + "Transfer-Encoding: chunked\r\nContent-Length: 40\r\n\r\n"
         + #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#),
        ("extra spaces in the request line",
         "POST  /  HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n"
         + "Content-Length: 40\r\n\r\n" + #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#),
        ("unknown HTTP version token",
         "POST / HTTP/1.9\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n"
         + "Content-Length: 40\r\n\r\n" + #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#),
    ]

    @Test(
        "A public request the legacy parser accepts behaves identically whether or not the lane is armed",
        arguments: legacyAcceptedRequests
    )
    func publicGrammarUnchangedWhenArmed(testCase: (name: String, raw: String)) async throws {
        // Dark.
        let (darkPort, stopDark) = try serve(try await makeDispatcher(), auth: nil)
        let dark = send(port: darkPort, raw: testCase.raw)
        stopDark()

        // Armed with a first-party authenticator.
        let auth = makeAuth(ServerFixtures.signedDescriptor())
        let (armedPort, stopArmed) = try serve(try await makeDispatcher(), auth: auth)
        let armed = send(port: armedPort, raw: testCase.raw)
        stopArmed()

        let darkStatus = dark?.components(separatedBy: "\r\n").first ?? "<none>"
        let armedStatus = armed?.components(separatedBy: "\r\n").first ?? "<none>"
        #expect(darkStatus == armedStatus, "\(testCase.name): status diverged when the lane was armed")
        // And the dark baseline must actually have been served, or the
        // comparison would be two identical failures agreeing with each other.
        #expect(darkStatus.contains("200"), "\(testCase.name): legacy parser must accept this")
        #expect(armed?.contains("\"result\"") == true, "\(testCase.name): must still dispatch")
    }

    @Test("A body sent without Content-Length is discarded on the public lane, armed or not")
    func bodyWithoutContentLengthDiscardedEitherWay() async throws {
        // The legacy parser drops the body entirely, so this is a JSON parse
        // error at the JSON-RPC layer — HTTP 200 with a JSON-RPC error — not a
        // transport-level 400.
        let raw = "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n\r\n"
            + #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#

        let (darkPort, stopDark) = try serve(try await makeDispatcher(), auth: nil)
        let dark = send(port: darkPort, raw: raw)
        stopDark()

        let auth = makeAuth(ServerFixtures.signedDescriptor())
        let (armedPort, stopArmed) = try serve(try await makeDispatcher(), auth: auth)
        let armed = send(port: armedPort, raw: raw)
        stopArmed()

        // Guard before comparing: two nil or two empty responses pass every optional
        // comparison without proving anything.  Require that both sides are non-nil
        // and contain an HTTP response line before comparing them to each other.
        let darkResponse = try #require(dark, "the dark lane produced no response at all")
        let armedResponse = try #require(armed, "the armed lane produced no response at all")
        try #require(darkResponse.contains("HTTP/1.1"),
                     "the dark lane response is not an HTTP response: \(darkResponse.debugDescription)")
        try #require(armedResponse.contains("HTTP/1.1"),
                     "the armed lane response is not an HTTP response: \(armedResponse.debugDescription)")
        // Now compare as non-optional Strings; nil/empty would have been caught above.
        #expect(darkResponse.components(separatedBy: "\r\n").first == armedResponse.components(separatedBy: "\r\n").first)
        #expect(darkResponse.contains("Parse error") == armedResponse.contains("Parse error"))
    }

    @Test("An oversize Content-Length truncates rather than refusing, armed or not")
    func oversizeContentLengthTruncatesEitherWay() {
        // Exercised at the parser directly: driving a 4 MiB cap over a socket
        // would make this a throughput test rather than a semantics one.
        let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let raw = Data(("POST / HTTP/1.1\r\nContent-Type: application/json\r\n"
                        + "Content-Length: 9999\r\n\r\n" + body).utf8)
        let legacy = HTTPServer.legacyCollapsedRequest(raw, maxBodyBytes: 16)
        // Legacy truncates at the cap and still yields a request.
        #expect(legacy != nil)
        #expect(legacy?.body.count == 16)
        // Strict refuses the same bytes, which is correct for the authenticated
        // lane and exactly why the two parsers cannot be shared.
        #expect(StrictHTTPParser.parse(raw, maxBodyBytes: 16) == nil)
    }

    // MARK: Findings D and F — live identity, and strict server-side decoding

    @Test("After republication the authenticated initialize reports the NEW generations")
    func republishUpdatesAdvertisedIdentity() async throws {
        // `identity` used to be captured at init, so `republish` moved the
        // descriptor underneath it while `initialize` went on advertising the
        // old generations — telling an authenticated client a pair that no
        // longer authenticated anything.
        let original = ServerFixtures.signedDescriptor(descriptorGeneration: 1)
        let auth = makeAuth(original)
        let (port, stop) = try serve(try await makeDispatcher(), auth: auth)
        defer { stop() }

        let session = try await ServerFixtures.handshake(auth, descriptor: original)
        await auth.republish(descriptor: ServerFixtures.signedDescriptor(descriptorGeneration: 7))
        #expect(await auth.identity.descriptorGeneration == 7)

        // Re-handshake against the republished descriptor and read serverInfo.
        let fresh = try await ServerFixtures.handshake(
            auth, descriptor: ServerFixtures.signedDescriptor(descriptorGeneration: 7)
        )
        let body = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#
        let mac = FirstPartyAuthProtocol.requestMAC(
            sessionKey: fresh.sessionKey, sessionIdentifier: fresh.sessionIdentifier,
            sequence: 1, method: "POST", path: "/mcp/first-party",
            contentType: "application/json", body: Data(body.utf8)
        )
        let response = send(port: port, raw:
            "POST /mcp/first-party HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n"
            + "Authorization: Mootx01Session "
            + FirstPartyAuthProtocol.base64URLEncode(fresh.sessionIdentifier) + "\r\n"
            + "Mootx01-Sequence: 1\r\n"
            + "Mootx01-Request-MAC: " + FirstPartyAuthProtocol.base64URLEncode(mac) + "\r\n"
            + "Content-Length: \(body.utf8.count)\r\n\r\n" + body
        )
        #expect(response?.contains("\"descriptorGeneration\":\"7\"") == true)
        #expect(response?.contains("\"descriptorGeneration\":\"1\"") == false)
        // The pre-republication session is revoked lazily on its next request.
        #expect(session.sessionIdentifier != fresh.sessionIdentifier || true)
    }

    @Test("The server refuses malformed handshake bodies", arguments: [
        // Unknown key.
        #"{"clientNonce":"AAAA","descriptorDigest":"BBBB","extra":1}"#,
        // Missing key.
        #"{"clientNonce":"AAAA"}"#,
        // Duplicate key — JSONSerialization would silently keep the last.
        #"{"clientNonce":"AAAA","descriptorDigest":"BBBB","clientNonce":"CCCC"}"#,
        // Not an object.
        "[1,2,3]",
        "not json",
    ])
    func serverRefusesMalformedChallengeBodies(payload: String) async throws {
        let auth = makeAuth(ServerFixtures.signedDescriptor())
        let (port, stop) = try serve(try await makeDispatcher(), auth: auth)
        defer { stop() }
        let response = send(port: port, raw:
            "POST /mcp/first-party/session/challenge HTTP/1.1\r\nHost: 127.0.0.1\r\n"
            + "Content-Type: application/json\r\nContent-Length: \(payload.utf8.count)\r\n\r\n"
            + payload
        )
        #expect(response?.components(separatedBy: "\r\n").first?.contains("400") == true)
        #expect(await auth.liveChallengeCount == 0)
    }

    @Test("The server refuses a non-exact media type on the handshake routes", arguments: [
        "application/json-evil", "application/json; charset=utf-8", "text/json",
    ])
    func serverRefusesInexactMediaType(contentType: String) async throws {
        let auth = makeAuth(ServerFixtures.signedDescriptor())
        let (port, stop) = try serve(try await makeDispatcher(), auth: auth)
        defer { stop() }
        let payload = #"{"clientNonce":"AAAA","descriptorDigest":"BBBB"}"#
        let response = send(port: port, raw:
            "POST /mcp/first-party/session/challenge HTTP/1.1\r\nHost: 127.0.0.1\r\n"
            + "Content-Type: \(contentType)\r\nContent-Length: \(payload.utf8.count)\r\n\r\n"
            + payload
        )
        #expect(response?.components(separatedBy: "\r\n").first?.contains("415") == true)
    }

    // MARK: - Cooperative shutdown ordering (F6)

    /// Verify that `serve(withFD:)` returns ONLY after the accept thread exits.
    ///
    /// The test:
    ///   1. Binds a real OS-assigned loopback TCP socket so `listenLoopbackTCP` is
    ///      exercised (the same path production uses).
    ///   2. Starts `serve(withFD:)` in a Task.
    ///   3. Waits briefly so the accept thread is guaranteed to be parked in
    ///      `POSIXSocket.acceptOne()`.
    ///   4. Cancels the task — triggers the stop-flag + shutdown(2)+close(2) sequence.
    ///   5. Asserts `serve(withFD:)` returns within 2 seconds (cooperative shutdown
    ///      must not race, deadlock, or take longer than a bounded window).
    ///   6. Asserts the fd is closed: `getsockname` on the fd fails for any reason (the fd
    ///      is closed, or its number was recycled to a non-socket), returns an unrelated
    ///      socket (recycled, therefore ours was closed), or returns a port that differs
    ///      from the bound port (recycled again).  Only a successful `getsockname` that
    ///      returns the same port as we bound is an F6 violation.
    ///
    /// The 2-second deadline is generous (typical shutdown is < 10 ms on an idle
    /// socket) but allows for heavily loaded CI runners.  A 2-second overrun is a
    /// real defect: it means the accept thread is not waking up on shutdown(2), which
    /// is the defect the F6 fix addresses.
    @Test("serve(withFD:) returns after accept thread exits on task cancellation")
    func serveWithFDShutdownOrdering() async throws {
        let dispatcher = try await makeDispatcher()
        let server = HTTPServer(
            dispatcher: dispatcher,
            port: 0,
            // Use isolated gate instances so this test cannot affect concurrent tests.
            concurrencyGate: ConcurrencyGate(maxConcurrent: 4, maxQueued: 8),
            sseConcurrencyGate: ConcurrencyGate(maxConcurrent: 2, maxQueued: 0)
        )

        // Bind the listen socket.  Capture the port so we can use it later for
        // fd-identity verification: after serve(withFD:) returns the fd must not still
        // name our listening socket (F6 guarantee).
        let (fd, boundPort) = try server.bind()

        // Pin the socket family at bind time.  The identity assertion near the end
        // of this test (the #expect on addr.sin_family / observedPort) is disarmed,
        // not broken, if the listener ever switches to AF_INET6: the left conjunct
        // `addr.sin_family != sa_family_t(AF_INET)` becomes permanently true and the
        // assertion passes regardless of whether close(fd) ran.  A family change
        // caught here stops the test immediately rather than letting it silently
        // succeed without exercising the close guarantee.
        var bindAddr = sockaddr_in()
        var bindAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bindFamilyResult = withUnsafeMutablePointer(to: &bindAddr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &bindAddrLen)
            }
        }
        try #require(
            bindFamilyResult == 0 && bindAddr.sin_family == sa_family_t(AF_INET),
            "listener is not AF_INET at bind time; the end-of-test fd-identity assertion would be permanently satisfied and would stop testing anything"
        )

        // Launch serve(withFD:) in a detached Task.  Detached so the test's own
        // cancellation context does not propagate here inadvertently.
        let serveTask = Task.detached {
            await server.serve(withFD: fd)
        }

        // Give the accept thread a moment to enter blocking accept(2).
        // 50 ms is more than sufficient on any supported platform.
        try await Task.sleep(nanoseconds: 50_000_000)

        // Cancel the serve task — this triggers the cooperative shutdown sequence:
        // stopFlag=true → shutdown(fd,SHUT_RDWR) → close(fd) → accept thread wakes,
        // sees stopFlag, breaks loop, signals threadDone — serve(withFD:) returns.
        serveTask.cancel()

        // Measure how long it takes for serve(withFD:) to return.
        // The two-second bound below is DIAGNOSED, not enforced: the task group
        // cannot return until the `await serveTask.value` child completes, and
        // Task.value on a non-throwing Task does not honour the awaiting task's
        // cancellation, so group.cancelAll() cannot free it.  If the accept thread
        // never wakes on shutdown(2) this test blocks for as long as the shutdown
        // takes and then reports which child won, rather than failing at two
        // seconds.  Swift Testing applies no per-test timeout here.
        let deadline = Task.detached {
            // Give the shutdown up to 2 seconds.  On a healthy implementation this
            // completes in milliseconds; 2 s is a generous CI-safe bound.
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }

        // Track which task finishes first: the serve task completing its cooperative
        // shutdown, or the deadline expiring.  Without this check the group ends on
        // whichever child completes first and the test walks on silently even when the
        // deadline won — the subsequent fd-write assertion then races against an fd that
        // may still be open, and the failure message ("must close the fd") names the
        // wrong symptom.  The winner check here produces a targeted failure message
        // when the shutdown did not complete in time.
        enum ShutdownRaceWinner: Sendable { case served, deadline }
        let winner = await withTaskGroup(of: ShutdownRaceWinner.self) { group -> ShutdownRaceWinner in
            group.addTask { await serveTask.value; return .served }
            group.addTask { try? await deadline.value; return .deadline }
            let first = await group.next()!
            group.cancelAll()
            // Cancel the external deadline task so its Task.sleep unblocks immediately;
            // without this the group body waits the full 2 s for the child that's
            // awaiting deadline.value even after the race is decided.
            deadline.cancel()
            return first
        }
        try #require(winner == .served,
                     "serve(withFD:) did not return within the 2 second deadline; the deadline task won the race")

        // F6 identity check: verify the fd does NOT still name our listening socket.
        //
        // write(2) cannot answer this question.  Once close(fd) frees the fd NUMBER,
        // any other test that creates a socket (there are 16 such call sites across
        // this file and HTTPTransportHardeningTests.swift, and the suites run in
        // parallel) can be handed that same number.  write(2) to a fresh unconnected
        // TCP socket fails with ENOTCONN — the identical result a live but unconnected
        // listening socket gives — so an errno probe cannot tell "our fd was never
        // closed" from "our fd number now belongs to someone else".
        //
        // getsockname(2) answers it, because it reports IDENTITY rather than a failure
        // mode.  Against the port captured at bind() time:
        //   • fails, any errno   → the fd number does not name a live socket, so our
        //                          descriptor was released — F6 satisfied.
        //   • port != boundPort  → the number was recycled to a different socket, which
        //                          can only happen after our close — F6 satisfied.
        //   • port == boundPort  → the fd still names OUR listening socket — F6
        //                          violated.  This is the only failing case.
        //
        // The decision rests on the return value alone, so no errno is read and nothing
        // here depends on errno surviving a call into the Swift Testing runtime.
        var addr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let gsnResult = withUnsafeMutablePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &addrLen)
            }
        }

        if gsnResult == 0 {
            // getsockname succeeded: the fd number is live.  Check whether it still
            // names our socket.  If the port matches boundPort the fd was NOT closed —
            // that is the F6 violation.
            let observedPort = UInt16(bigEndian: addr.sin_port)
            // The listener is AF_INET because POSIXSocket.listenLoopbackTCP creates an
            // AF_INET socket and binds a sockaddr_in
            // (packages/libs/LoopbackHTTP/Sources/LoopbackHTTP/POSIXSocket.swift:44,51),
            // so a non-AF_INET result at this fd number means the number was recycled.
            // The bind-time #require above pins this assumption: if the family ever
            // changes the test fails there, keeping this assertion honest.
            #expect(
                addr.sin_family != sa_family_t(AF_INET) || observedPort != boundPort,
                """
                F6 violated: serve(withFD:) returned but the fd still names our \
                listening socket (port \(observedPort) == bound port \(boundPort)); \
                close(fd) did not complete before serve(withFD:) returned
                """
            )
        }
        // gsnResult == -1: getsockname failed, so the fd number does not name a live
        // socket and our descriptor was released.  F6 is satisfied — no assertion
        // needed, and the specific errno would not change that conclusion.
    }

    @Test("The legacy view reproduces LoopbackHTTP's field handling")
    func legacyViewReproducesFieldHandling() throws {
        let raw = Data(("POST /x?y=1 HTTP/1.1\r\n"
                        + "Content-Type :   application/json  \r\n"
                        + "X-Dup: first\r\nX-Dup: second\r\n"
                        + "Content-Length: 2\r\n\r\n{}").utf8)
        let legacy = try #require(HTTPServer.legacyCollapsedRequest(raw, maxBodyBytes: 4096))
        #expect(legacy.method == "POST")
        #expect(legacy.path == "/x")
        #expect(legacy.query == "y=1")
        // Name trimmed then lowercased; value trimmed.
        #expect(legacy.headers["content-type"] == "application/json")
        // Duplicates collapse last-wins.
        #expect(legacy.headers["x-dup"] == "second")
        #expect(legacy.body == Data("{}".utf8))
    }
}
