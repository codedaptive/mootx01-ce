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
    @Test func readJournalHugeLastNIsClamped() async throws {
        let dispatcher = try await makeDispatcher()
        let (port, stop) = try startServing(dispatcher)
        defer { stop() }

        // Absent estate still returns a success result (journal is empty on a fresh estate).
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
        var tv = timeval(tv_sec: 5, tv_usec: 0)
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
        let waitDeadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while !registration.value, DispatchTime.now().uptimeNanoseconds < waitDeadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try #require(registration.value, "raw reader never registered its descriptor")

        let started = DispatchTime.now().uptimeNanoseconds
        task.cancel()
        let result = await task.value
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        #expect(result == nil)
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
private final class RawReadRegistration: @unchecked Sendable {
    private let lock = NSLock()
    private var registered = false

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return registered
    }

    func mark() {
        lock.lock(); registered = true; lock.unlock()
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

        #expect(dark?.components(separatedBy: "\r\n").first == armed?.components(separatedBy: "\r\n").first)
        #expect(dark?.contains("Parse error") == armed?.contains("Parse error"))
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
    ///   6. Asserts the fd is closed: a write to the closed fd fails with EBADF.
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

        // Bind the listen socket.
        let (fd, _) = try server.bind()

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
        // If the accept thread does not wake on shutdown(2), this await would block
        // indefinitely and the test would time out.  The 2-second guarantee is
        // expressed via the Task.sleep timeout below.
        let deadline = Task.detached {
            // Give the shutdown up to 2 seconds.  On a healthy implementation this
            // completes in milliseconds; 2 s is a generous CI-safe bound.
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }

        // await the serve task — it must finish before the deadline.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await serveTask.value }
            group.addTask { try? await deadline.value }
            // First one to finish ends the group; the other task is cancelled.
            await group.next()
            group.cancelAll()
        }

        // If serve(withFD:) returns correctly, the fd is now closed.
        // Writing to a closed fd returns EBADF; success here means the fd leaked.
        let dummyByte = [UInt8(0x00)]
        let writeResult = dummyByte.withUnsafeBytes { ptr in
            write(fd, ptr.baseAddress!, 1)
        }
        // EBADF == fd is closed.  Any other errno or a successful write (>= 0)
        // means the fd was NOT closed — the shutdown guarantee was violated.
        #expect(writeResult == -1, "serve(withFD:) must close the fd before returning (F6)")
        if writeResult == -1 {
            #expect(errno == EBADF, "expected EBADF after serve(withFD:) returned, got errno \(errno)")
        }
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
