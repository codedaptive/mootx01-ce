import Foundation
import LoopbackHTTP

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// The ARIA_MCP loopback HTTP transport (MCP "Streamable HTTP").
///
/// A resident, headless HTTP server bound to `127.0.0.1:<port>` that speaks the
/// SAME JSON-RPC 2.0 surface as `StdioServer`: a client POSTs one JSON-RPC frame
/// and receives one JSON-RPC frame as the response body. The wire bytes are
/// byte-identical to the stdio transport because both go through
/// `JSONValue.parse` on the way in and `JSONRPCResponse.asJSONValue.encoded()`
/// on the way out — only the framing differs (HTTP body vs newline-delimited).
///
/// This transport drives the existing, transport-neutral `ARIA_MCPDispatcher`
/// unchanged; the dispatcher does not know or care which transport invoked it.
/// stdio remains the default transport (testing, migrations); the resident HTTP
/// server is selected by `AriaMCPMain` when `MOOTX01_HTTP_PORT` is set.
///
/// SCOPE (P1b): request→response only. Server-initiated SSE streaming
/// (notifications from the Brain pump) is deferred until there are notifications
/// to push (P2); `LoopbackHTTP.SSEStream` is ready for that and intentionally
/// unused here.
///
/// SECURITY: the listener binds loopback only (`POSIXSocket.listenLoopbackTCP`
/// hard-pins `INADDR_LOOPBACK`). Per ADR-LOOPBACKHTTP-001 there is no
/// authentication on the Community-Edition transport, but `route` enforces a
/// CSRF/DNS-rebinding guard: a request whose `Origin` is present and non-loopback
/// is rejected (403) before dispatch (`bearerToken` is read for logging only).
/// The Enterprise OAuth layer composes ABOVE this transport in v2, never inside it.
public struct HTTPServer: Sendable {

    public let dispatcher: ARIA_MCPDispatcher
    /// TCP port on 127.0.0.1 (0 = OS-assigned, used by tests).
    public let port: UInt16
    /// Maximum request body. MCP `tools/call` argument bodies can exceed
    /// LoopbackHTTP's 64 KiB default, which would silently truncate — so the
    /// transport sets a large cap (ADR-LOOPBACKHTTP-001 condition 2). Default
    /// 4 MiB; `AriaMCPMain` overrides from `MOOTX01_HTTP_MAX_BODY_BYTES`.
    public let maxBodyBytes: Int

    public init(dispatcher: ARIA_MCPDispatcher, port: UInt16 = 4242, maxBodyBytes: Int = 4 * 1024 * 1024) {
        self.dispatcher = dispatcher
        self.port = port
        self.maxBodyBytes = maxBodyBytes
    }

    /// Bind the loopback listener and serve until the process is terminated.
    ///
    /// The blocking `accept()` loop runs on a dedicated thread so it never
    /// occupies the cooperative pool; each accepted connection is served on its
    /// own `Task` (concurrent, mirroring moot-mgr's HTTPReadAPI). A resident
    /// daemon never returns from `run()` — the process exits on SIGTERM from
    /// launchd. Connection-count limits / hardening are a later (P4) concern.
    ///
    /// - Returns: the bound port (only meaningful for the OS-assigned `port: 0`
    ///   test path, which calls `bind()` and inspects `boundPort` instead of
    ///   blocking; production callers pass a fixed port and never return).
    /// - Throws: `SocketError` if the loopback socket cannot be bound (e.g.
    ///   `EADDRINUSE` when the port is already taken).
    public func run() async throws {
        let listenFD = try bind().fd
        let dispatcher = self.dispatcher
        let maxBody = self.maxBodyBytes
        let thread = Thread {
            while true {
                guard let cfd = POSIXSocket.acceptOne(listenFD) else { continue }
                Task { await HTTPServer.serve(cfd, dispatcher: dispatcher, maxBodyBytes: maxBody) }
            }
        }
        thread.name = "com.mootx01.aria-mcp.http.accept"
        thread.start()
        // Resident: the blocking accept loop runs on its own thread above. Park
        // this async function until the task is cancelled (process shutdown) with
        // a cancellable sleep loop — NOT a leaked continuation, which the Swift
        // runtime flags as "continuation misuse." Task.sleep throws on cancel,
        // which exits the loop cleanly.
        while !Task.isCancelled {
            do { try await Task.sleep(nanoseconds: 3_600_000_000_000) }  // 1h, re-armed
            catch { break }
        }
    }

    /// Bind the loopback listener without entering the accept loop. Used by tests
    /// (port 0) to drive a single connection deterministically; production uses
    /// `run()`.
    public func bind() throws -> (fd: Int32, port: UInt16) {
        let (fd, boundPort) = try POSIXSocket.listenLoopbackTCP(port: port)
        Logging.stderr.log("ARIA_MCP HTTP listening on 127.0.0.1:\(boundPort) (max body \(maxBodyBytes) bytes)")
        return (fd, boundPort)
    }

    /// Serve one accepted connection: read the request, route it, write the
    /// response, close. Static so the accept thread captures only `Sendable`
    /// values, not the struct's storage.
    static func serve(_ fd: Int32, dispatcher: ARIA_MCPDispatcher, maxBodyBytes: Int) async {
        defer { close(fd) }
        guard let request = HTTPRequest.read(fd: fd, maxBodyBytes: maxBodyBytes) else { return }
        let response = await route(request, dispatcher: dispatcher)
        response.send(fd: fd)
    }

    /// Route one HTTP request to an HTTP response carrying a JSON-RPC frame.
    ///
    /// MCP Streamable HTTP: the JSON-RPC request arrives as the POST body. The
    /// parse → decode → dispatch → encode path is identical to
    /// `StdioServer.handleFrame`, so the JSON-RPC bytes match across transports.
    /// JSON-RPC-level failures return HTTP 200 with a JSON-RPC error object (the
    /// error lives in the body, per JSON-RPC-over-HTTP convention); a
    /// notification (no id) gets HTTP 202 with no body.
    static func route(_ request: HTTPRequest, dispatcher: ARIA_MCPDispatcher) async -> HTTPResponse {
        // DNS-rebinding / CSRF guard (runs first). A loopback HTTP endpoint is
        // reachable from a browser tab via a domain that resolves to 127.0.0.1;
        // the page's request then carries that domain as its Origin. Native MCP
        // clients (Claude Code/Desktop, Codex CLI) send no Origin at all. So:
        // accept absent/loopback Origins, reject everything else. This is a CSRF
        // boundary, NOT authentication — it stays in the consumer (here), never
        // in LoopbackHTTP (ADR-LOOPBACKHTTP-001). Matches moot-mgr's
        // HTTPReadAPI.isOriginAllowed. The EE OAuth layer composes above this.
        guard Self.isOriginAllowed(request.origin) else {
            return HTTPResponse(
                status: 403,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":"forbidden_origin"}"#.utf8)
            )
        }

        guard request.method == "POST" else {
            return HTTPResponse(
                status: 405,
                headers: ["Content-Type": "application/json", "Allow": "POST"],
                body: Data(#"{"error":"method_not_allowed"}"#.utf8)
            )
        }

        let parsed: JSONValue
        do {
            parsed = try JSONValue.parse(request.body)
        } catch {
            return jsonRPCError(.null, code: JSONRPCErrorCode.parseError, message: "Parse error: \(error)")
        }

        guard let rpc = JSONRPCRequest.decode(parsed) else {
            return jsonRPCError(.null, code: JSONRPCErrorCode.invalidRequest, message: "Invalid Request: malformed JSON-RPC envelope")
        }

        guard let response = await dispatcher.handle(rpc) else {
            // Notification: the JSON-RPC spec forbids a reply. HTTP carries that
            // as 202 Accepted with an empty body.
            return HTTPResponse(status: 202)
        }

        return encodedResponse(response)
    }

    /// Encode a JSON-RPC response into a 200 application/json HTTP response,
    /// matching `StdioServer.write`'s serialization exactly.
    static func encodedResponse(_ response: JSONRPCResponse) -> HTTPResponse {
        do {
            let body = try response.asJSONValue.encoded()
            return .json(status: 200, body: body)
        } catch {
            Logging.stderr.log("HTTP response encode failed: \(error)")
            return jsonRPCError(.null, code: JSONRPCErrorCode.internalError, message: "Internal error: \(error)")
        }
    }

    /// Build a 200 response whose body is a JSON-RPC error object.
    static func jsonRPCError(_ id: JSONValue, code: Int, message: String) -> HTTPResponse {
        let response = JSONRPCResponse.failure(id, JSONRPCError(code: code, message: message))
        let body = (try? response.asJSONValue.encoded())
            ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"internal error"}}"#.utf8)
        return .json(status: 200, body: body)
    }

    /// True if the request's Origin is acceptable: absent (native MCP clients
    /// send none) or a loopback origin. Any other origin is a cross-origin
    /// browser request (the DNS-rebinding vector) and is rejected. Mirrors
    /// moot-mgr's `HTTPReadAPI.isOriginAllowed`.
    static func isOriginAllowed(_ origin: String?) -> Bool {
        guard let origin, !origin.isEmpty else { return true }
        let lowered = origin.lowercased()
        return lowered.hasPrefix("http://127.0.0.1")
            || lowered.hasPrefix("http://localhost")
            || lowered.hasPrefix("https://127.0.0.1")
            || lowered.hasPrefix("https://localhost")
            || lowered.hasPrefix("http://[::1]")
            || lowered.hasPrefix("https://[::1]")
    }
}
