import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
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

    /// Build a dispatcher wired to a fresh in-memory estate (mirrors ServerTests).
    private func makeDispatcher() async throws -> ARIA_MCPDispatcher {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-mcp-http-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        let info = ARIA_MCPDispatcher.ServerInfo(name: "ARIA_MCP", version: "test")
        let tooling = ToolDispatcher(kit: kit, handle: handle)
        return ARIA_MCPDispatcher(info: info, tooling: tooling)
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
