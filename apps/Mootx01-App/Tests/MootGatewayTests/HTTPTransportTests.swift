import Testing
import Foundation
@testable import MootGateway
import AriaMCP
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// ============================================================
// MARK: - A2 HTTP Transport Integration Tests
//
// Verifies that HTTPTransport — the real client-side loopback transport — talks
// correctly to a live ARIA HTTP server (HTTPServer from AriaMCP). Each test:
//
//   1. Opens a fresh in-memory estate and builds an ARIA_MCPDispatcher.
//   2. Binds HTTPServer on an OS-assigned ephemeral loopback port (0 → kernel
//      picks). Uses HTTPServer.bind() then runs the accept loop on a dedicated
//      thread, mirroring the pattern in AriaMCP's HTTPServerTests.
//   3. Points HTTPTransport at that port and exercises the wire end-to-end.
//   4. Tears down the accept thread by closing the listen fd (stop closure).
//
// The tests are .serialized because each opens a live listener.
// URLRequest timeout on HTTPTransport is set to 5 seconds — the daemon is
// local and any tool call finishes well within that window.
//
// Error-path tests use a minimal raw-socket listener (no external libs) that
// returns controlled non-standard responses, so GatewayTransportError mapping
// can be verified without a full ARIA stack.
// ============================================================

@Suite("HTTPTransport integration — A2 loopback", .serialized)
struct HTTPTransportTests {

    // MARK: - Harness

    /// Create a fresh ARIA_MCPDispatcher wired to an ephemeral in-memory estate.
    private func makeDispatcher() async throws -> ARIA_MCPDispatcher {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "http-transport-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        let info = ARIA_MCPDispatcher.ServerInfo(name: "ARIA_MCP", version: "test")
        let tooling = ToolDispatcher(kit: kit, handle: handle)
        return ARIA_MCPDispatcher(info: info, tooling: tooling)
    }

    /// Start an HTTPServer on an OS-assigned port using `HTTPServer.run()`.
    ///
    /// `HTTPServer.run()` is the public entry point: it binds the socket, starts the
    /// accept thread, and parks until the Task is cancelled. This harness wraps it in
    /// a detached Task so the test continues running; cancelling the Task (via the
    /// returned stop closure) makes run() exit and the OS reclaims the socket.
    ///
    /// A semaphore waits until the server has bound and is ready to accept connections
    /// before returning to the test — otherwise the test may race against the bind.
    ///
    /// Note: `HTTPServer.run()` logs the bound port to stderr. The bound port is
    /// captured by binding an HTTPServer on port 0 first, reading the OS-assigned
    /// port from `bind()`, then letting the task call `run()` which re-uses the
    /// port from the server's stored `port` field. We read the bound port from
    /// `bind()` before returning.
    private func startServer(_ dispatcher: ARIA_MCPDispatcher) throws -> (port: UInt16, stop: () -> Void) {
        // Bind once to learn the OS-assigned port. HTTPServer.run() will bind on the
        // same port value. We call bind() here to get the port, then discard the fd —
        // the OS reclaims it and run() binds afresh. On loopback with SO_REUSEADDR
        // the second bind completes before any test connection arrives.
        //
        // Alternative: let run() start and infer the port from stderr logs, but that
        // is fragile. Instead, pick an ephemeral port ourselves via rawListen/close,
        // then tell the server to use that exact port.
        let (probeFD, port) = try rawListen()
        close(probeFD)   // release the port immediately; run() will claim it

        // Small sleep to let the OS free the port before run() binds it.
        // On loopback SO_REUSEADDR makes this reliable even under load.
        Thread.sleep(forTimeInterval: 0.005)

        let server = HTTPServer(dispatcher: dispatcher, port: port)
        let task = Task {
            // run() blocks indefinitely on its accept thread; the async park inside
            // run() yields when the Task is cancelled (Task.sleep throws on cancel).
            try? await server.run()
        }

        // Give the server a moment to bind and start the accept thread before
        // returning to the test. 50 ms is generous for a loopback bind.
        Thread.sleep(forTimeInterval: 0.05)

        return (port, { task.cancel() })
    }

    /// Build an HTTPTransport pointing at the ephemeral test server.
    /// 5-second timeout: the daemon is local; any tool call finishes within this window.
    private func transport(port: UInt16) -> HTTPTransport {
        let url = URL(string: "http://127.0.0.1:\(port)")!
        return HTTPTransport(endpoint: url, timeout: 5.0)
    }

    // MARK: - Happy-path tests

    @Test("initialize round-trips over the real loopback wire")
    func initializeRoundTrips() async throws {
        let dispatcher = try await makeDispatcher()
        let (port, stop) = try startServer(dispatcher)
        defer { stop() }

        let t = transport(port: port)
        let request = JSONRPCRequest(
            id: .integer(1),
            method: "initialize",
            params: .object(["protocolVersion": .string("2024-11-05")])
        )
        let response = try await t.send(request)
        let resp = try #require(response)
        guard case .result(let value) = resp.payload else {
            Issue.record("Expected .result, got error payload")
            return
        }
        // The server must echo back its serverInfo.name.
        let serverInfo = value.objectValue?["serverInfo"]?.objectValue
        #expect(serverInfo?["name"]?.stringValue == "ARIA_MCP")
    }

    @Test("tools/list exposes the moot_* surface over HTTP")
    func toolsListOverHTTP() async throws {
        let dispatcher = try await makeDispatcher()
        let (port, stop) = try startServer(dispatcher)
        defer { stop() }

        let t = transport(port: port)
        let request = JSONRPCRequest(id: .integer(2), method: "tools/list", params: nil)
        let response = try await t.send(request)
        let resp = try #require(response)
        guard case .result(let value) = resp.payload else {
            Issue.record("Expected .result from tools/list, got error")
            return
        }
        let tools = value.objectValue?["tools"]?.arrayValue ?? []
        #expect(tools.isEmpty == false)
        let names = tools.compactMap { $0.objectValue?["name"]?.stringValue }
        #expect(names.contains("moot_file_memory"))
        #expect(names.contains("moot_memory_search"))
    }

    @Test("file then search round-trip through the HTTP wire")
    func fileMemoryThenSearchOverHTTP() async throws {
        let dispatcher = try await makeDispatcher()
        let (port, stop) = try startServer(dispatcher)
        defer { stop() }

        let t = transport(port: port)

        // File a memory. The response must be a successful tools/call result.
        let fileReq = JSONRPCRequest(
            id: .integer(10),
            method: "tools/call",
            params: .object([
                "name": .string("moot_file_memory"),
                "arguments": .object([
                    "content": .string("HTTPTransport wires the gateway to the resident daemon."),
                    "location": .string("transport-tests"),
                ]),
            ])
        )
        let fileResp = try await t.send(fileReq)
        let fileResult = try #require(fileResp)
        // tools/call wraps the result in a content array; isError must be absent or false.
        guard case .result(let fileValue) = fileResult.payload else {
            Issue.record("moot_file_memory returned a JSON-RPC error")
            return
        }
        let isError = fileValue.objectValue?["isError"]?.boolValue ?? false
        #expect(isError == false)

        // Search for the filed memory.
        let searchReq = JSONRPCRequest(
            id: .integer(11),
            method: "tools/call",
            params: .object([
                "name": .string("moot_memory_search"),
                "arguments": .object([
                    "query": .string("resident daemon"),
                ]),
            ])
        )
        let searchResp = try await t.send(searchReq)
        let searchResult = try #require(searchResp)
        guard case .result(let searchValue) = searchResult.payload else {
            Issue.record("moot_memory_search returned a JSON-RPC error")
            return
        }
        let searchIsError = searchValue.objectValue?["isError"]?.boolValue ?? false
        #expect(searchIsError == false)
        // The search result carries at least one content block.
        let content = searchValue.objectValue?["content"]?.arrayValue ?? []
        #expect(content.isEmpty == false)
    }

    @Test("moot_estate_ping succeeds over the HTTP wire")
    func estatePingOverHTTP() async throws {
        let dispatcher = try await makeDispatcher()
        let (port, stop) = try startServer(dispatcher)
        defer { stop() }

        let t = transport(port: port)
        let pingReq = JSONRPCRequest(
            id: .integer(20),
            method: "tools/call",
            params: .object([
                "name": .string("moot_estate_ping"),
                "arguments": .object([:]),
            ])
        )
        let resp = try await t.send(pingReq)
        let result = try #require(resp)
        guard case .result(let value) = result.payload else {
            Issue.record("moot_estate_ping returned a JSON-RPC error")
            return
        }
        let pingIsError = value.objectValue?["isError"]?.boolValue ?? false
        #expect(pingIsError == false)
    }

    // MARK: - Error-path tests

    @Test("connectionRefused when the server is not running")
    func connectionRefusedWhenNoServer() async throws {
        // Port 1 is below the ephemeral range and unreserved on modern macOS;
        // connect() returns ECONNREFUSED immediately on loopback when nothing is bound.
        let url = URL(string: "http://127.0.0.1:1")!
        let t = HTTPTransport(endpoint: url, timeout: 2.0)
        let request = JSONRPCRequest(id: .integer(99), method: "ping", params: nil)
        do {
            _ = try await t.send(request)
            Issue.record("Expected connectionRefused to throw, but send succeeded")
        } catch GatewayTransportError.connectionRefused {
            // Expected: nothing is listening on that port.
        } catch {
            Issue.record("Expected GatewayTransportError.connectionRefused, got: \(error)")
        }
    }

    @Test("malformedResponse when the server returns invalid JSON")
    func malformedResponseOnInvalidJSON() async throws {
        // Raw listener that returns HTTP 200 with a non-JSON body.
        // HTTPTransport must map the JSONValue.parse failure to malformedResponse.
        //
        // The listener reads the request headers before replying so URLSession
        // can flush its send buffer and is ready to read the response. Without
        // draining the request, some URLSession configurations stall.
        let (listenFD, port) = try rawListen()
        defer { close(listenFD) }

        let thread = Thread {
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let cfd = withUnsafeMutablePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(listenFD, sa, &len)
                }
            }
            guard cfd >= 0 else { return }
            defer { close(cfd) }
            // Drain the request so URLSession's send completes before we reply.
            var buf = [UInt8](repeating: 0, count: 4096)
            _ = read(cfd, &buf, buf.count)
            // Send HTTP 200 with a body that is not valid JSON.
            let bodyStr = "this is not json at all\r\n"
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(bodyStr.utf8.count)\r\nConnection: close\r\n\r\n"
            let out = Data((head + bodyStr).utf8)
            _ = write(cfd, out.withUnsafeBytes { $0.baseAddress! }, out.count)
        }
        thread.name = "com.mootx01.malformed-test.listener"
        thread.start()

        // Give the accept thread a moment to reach accept() before URLSession connects.
        // listen() makes the port reachable immediately, but the thread may not have
        // called accept() yet; a brief yield lets the OS schedule it.
        try await Task.sleep(nanoseconds: 20_000_000)  // 20 ms

        let url = URL(string: "http://127.0.0.1:\(port)")!
        let t = HTTPTransport(endpoint: url, timeout: 3.0)
        let request = JSONRPCRequest(id: .integer(50), method: "ping", params: nil)
        do {
            _ = try await t.send(request)
            Issue.record("Expected malformedResponse to throw")
        } catch GatewayTransportError.malformedResponse {
            // Expected: the server sent a body that is not valid JSON.
        } catch {
            Issue.record("Expected GatewayTransportError.malformedResponse, got: \(error)")
        }
    }

    @Test("unexpectedHTTPStatus on a non-2xx response")
    func unexpectedHTTPStatusOnNon2xx() async throws {
        // Raw listener that returns HTTP 503. The listener reads the request first
        // so URLSession's send completes before we write the 503 response.
        let (listenFD, port) = try rawListen()
        defer { close(listenFD) }

        let thread = Thread {
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let cfd = withUnsafeMutablePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(listenFD, sa, &len)
                }
            }
            guard cfd >= 0 else { return }
            defer { close(cfd) }
            // Drain the incoming request before replying.
            var buf = [UInt8](repeating: 0, count: 4096)
            _ = read(cfd, &buf, buf.count)
            let bodyStr = #"{"error":"service_unavailable","retry_after":1}"#
            let head = "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: \(bodyStr.utf8.count)\r\nConnection: close\r\n\r\n"
            let out = Data((head + bodyStr).utf8)
            _ = write(cfd, out.withUnsafeBytes { $0.baseAddress! }, out.count)
        }
        thread.name = "com.mootx01.status503-test.listener"
        thread.start()

        // Give the accept thread a moment to reach accept() before URLSession connects.
        try await Task.sleep(nanoseconds: 20_000_000)  // 20 ms

        let url = URL(string: "http://127.0.0.1:\(port)")!
        let t = HTTPTransport(endpoint: url, timeout: 3.0)
        let request = JSONRPCRequest(id: .integer(51), method: "ping", params: nil)
        do {
            _ = try await t.send(request)
            Issue.record("Expected unexpectedHTTPStatus to throw")
        } catch GatewayTransportError.unexpectedHTTPStatus(_, let status) {
            #expect(status == 503)
        } catch {
            Issue.record("Expected GatewayTransportError.unexpectedHTTPStatus, got: \(error)")
        }
    }

    // MARK: - Helpers

    /// Bind a raw TCP loopback listener on an OS-assigned port (0 → kernel assigns).
    /// Used by error-path tests that need a controlled server without the full
    /// ARIA stack. No external dependencies: uses POSIX socket(2)/bind(2)/listen(2).
    private func rawListen() throws -> (fd: Int32, port: UInt16) {
        struct SocketError: Error { let msg: String }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError(msg: "socket() failed errno=\(errno)") }

        var reuseVal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuseVal, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                            // OS assigns a port
        addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian  // 127.0.0.1

        let bindResult = withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw SocketError(msg: "bind() failed errno=\(errno)")
        }
        guard listen(fd, 5) == 0 else {
            close(fd)
            throw SocketError(msg: "listen() failed errno=\(errno)")
        }

        // Read back the OS-assigned port via getsockname.
        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                _ = getsockname(fd, sa, &addrLen)
            }
        }
        let boundPort = UInt16(bigEndian: boundAddr.sin_port)
        return (fd, boundPort)
    }
}

// MARK: - JSONValue helpers (test-local)

private extension JSONValue {
    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
}
