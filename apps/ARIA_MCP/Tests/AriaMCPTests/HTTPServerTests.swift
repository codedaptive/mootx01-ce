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
    /// dedicated accept thread (mirrors `HTTPServer.run`'s internals). Returns the
    /// bound port and a stop closure; closing the listener unblocks accept so the
    /// thread exits.
    private func startServing(_ dispatcher: ARIA_MCPDispatcher) throws -> (port: UInt16, stop: () -> Void) {
        let server = HTTPServer(dispatcher: dispatcher, port: 0)
        let (listenFD, port) = try server.bind()
        let thread = Thread {
            while let cfd = POSIXSocket.acceptOne(listenFD) {
                Task { await HTTPServer.serve(cfd, dispatcher: dispatcher, maxBodyBytes: 4 * 1024 * 1024) }
            }
        }
        thread.name = "aria-mcp.http.test.accept"
        thread.start()
        return (port, { close(listenFD) })
    }

    /// Open a client connection to 127.0.0.1:port, send one HTTP request, and read
    /// the full response (the server sends `Connection: close`, so read to EOF).
    private func httpRequest(port: UInt16, method: String, body: String, origin: String? = nil) -> (status: Int, body: Data)? {
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
        let head = "\(method) / HTTP/1.1\r\nHost: 127.0.0.1\r\n\(originLine)Content-Type: application/json\r\nContent-Length: \(bodyData.count)\r\n\r\n"
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

        let result = try #require(httpRequest(port: port, method: "GET", body: ""))
        #expect(result.status == 405)
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
}
