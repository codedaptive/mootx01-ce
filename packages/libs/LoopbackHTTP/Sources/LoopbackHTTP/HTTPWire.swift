// HTTPWire.swift
//
// A minimal HTTP/1.1 request reader, a general buffered-response writer, and an
// SSE streaming primitive over a POSIX socket fd. NO external HTTP package (no
// SwiftNIO) — the small, purpose-built parser the zero-dependency rule requires.
//
// Scope is intentionally narrow: it parses a request line + headers + an
// optional Content-Length body, writes a single buffered response, and frames a
// Server-Sent-Events stream. It is NOT a general-purpose HTTP server.
//
// Generalized in P1a (bounded loopback HTTP, condition 1): the response is a
// value (status + headers + body) the CALLER composes — not a closed set of
// consumer-specific cases — and SSE is a consumer-driven `SSEStream` (this type
// owns the `text/event-stream` framing; the consumer owns the stream source and
// the connection lifetime). This lets both moot-mgr's dashboard read-API and the
// resident MCP transport consume one contract.
//
// AUTH-FREE INVARIANT (bounded loopback HTTP, condition 3): nothing here knows
// about tokens, Origin, or OAuth. `HTTPRequest` exposes `bearerToken`/`origin`
// as conveniences for a consumer to read; the decision to accept or reject lives
// in the consumer, above the transport.

import Foundation

// MARK: - HTTPRequest

/// A parsed HTTP/1.1 request: method, path, headers, and an optional body.
public struct HTTPRequest: Sendable {
    public let method: String
    /// The path WITHOUT the query string (query is parsed into `query`).
    public let path: String
    /// Raw query string after '?', or "" if none.
    public let query: String
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, query: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    /// The Bearer token from the Authorization header, or nil. Convenience only —
    /// the accept/reject decision is the consumer's, never this library's.
    public var bearerToken: String? {
        guard let auth = headers["authorization"] else { return nil }
        let prefix = "bearer "
        guard auth.lowercased().hasPrefix(prefix) else { return nil }
        return String(auth.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    /// The Origin header value, or nil. Convenience only (see `bearerToken`).
    public var origin: String? { headers["origin"] }

    /// Whether the client asked for the SSE event stream (Accept header or
    /// the `?stream=1` query flag). The `?stream=1` flag is a consumer
    /// convenience (moot-mgr's dashboard sets it); a consumer that doesn't use it
    /// simply relies on the Accept header.
    ///
    /// CSRF NOTE: SSE connections opened by a browser with `?stream=1` are GET
    /// requests, so the browser's CORS preflight does NOT run for same-origin
    /// policies — a malicious page on a different origin can open an SSE connection
    /// if the loopback address is reachable from the browser. Consumers that
    /// expose sensitive data over SSE MUST validate the `Origin` header
    /// (`request.origin`) and reject connections from unexpected origins before
    /// upgrading to an event stream. The transport does not enforce this (per
    /// bounded loopback HTTP condition 3 — auth/origin decisions belong to the
    /// consumer layer above this library).
    public var wantsEventStream: Bool {
        if let accept = headers["accept"], accept.contains("text/event-stream") { return true }
        // Use exact parameter matching rather than substring containment.
        // `query.contains("stream=1")` would match "stream=10", "mystream=1",
        // or "x=stream=1", incorrectly triggering SSE mode for unrelated requests.
        let params = query.split(separator: "&", omittingEmptySubsequences: true)
        return params.contains(where: { $0 == "stream=1" })
    }

    /// Read and parse one request from socket `fd`.
    ///
    /// Reads until the header terminator (CRLF CRLF), then reads exactly
    /// Content-Length more bytes for the body if present. Returns nil on a
    /// malformed request or socket error.
    ///
    /// - Parameters:
    ///   - fd: The connected socket descriptor.
    ///   - maxHeaderBytes: Cap on the header block; a request whose headers
    ///     exceed this is rejected (nil). Per-listener (bounded loopback HTTP
    ///     condition 2): a dashboard control listener wants a small cap; an MCP
    ///     `tools/call` listener wants a large one.
    ///   - maxBodyBytes: Cap on the body. The body is read up to this many bytes.
    ///     NOTE: at the cap the body is truncated, not errored — a consumer that
    ///     must reject oversize bodies (e.g. the MCP listener) should set this
    ///     high enough that truncation cannot corrupt a valid request, or detect
    ///     a Content-Length that exceeds its cap before calling.
    public static func read(
        fd: Int32,
        maxHeaderBytes: Int = 64 * 1024,
        maxBodyBytes: Int = 64 * 1024
    ) -> HTTPRequest? {
        var buffer = Data()
        while true {
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                return parse(buffer: buffer, headerEnd: range.upperBound, fd: fd, maxBodyBytes: maxBodyBytes)
            }
            if buffer.count > maxHeaderBytes { return nil }
            guard let chunk = POSIXSocket.recv(fd, max: 16 * 1024), !chunk.isEmpty else {
                return nil
            }
            buffer.append(chunk)
        }
    }

    /// Parse the buffered header block, reading the body if Content-Length says so.
    private static func parse(buffer: Data, headerEnd: Data.Index, fd: Int32, maxBodyBytes: Int) -> HTTPRequest? {
        let headerData = buffer[buffer.startIndex..<headerEnd]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let target = String(parts[1])
        let (path, query): (String, String) = {
            if let q = target.firstIndex(of: "?") {
                return (String(target[target.startIndex..<q]), String(target[target.index(after: q)...]))
            }
            return (target, "")
        }()

        // Header lines (skip the request line; stop at the blank line).
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        // Body: read exactly Content-Length bytes (anything already buffered
        // after the header terminator counts), bounded by maxBodyBytes.
        var body = Data(buffer[headerEnd...])
        if let lenStr = headers["content-length"], let len = Int(lenStr), len > 0 {
            let want = min(len, maxBodyBytes)
            while body.count < want {
                guard let chunk = POSIXSocket.recv(fd, max: 16 * 1024), !chunk.isEmpty else { break }
                body.append(chunk)
            }
            if body.count > want { body = body.prefix(want) }
        } else {
            body = Data()
        }

        return HTTPRequest(method: method, path: path, query: query, headers: headers, body: body)
    }
}

// MARK: - HTTPResponse

/// A buffered HTTP/1.1 response the caller composes: a status code, headers, and
/// a body. The library writes the wire bytes (`send(fd:)`); the caller decides
/// what the response means. Convenience constructors cover the common shapes
/// without making them the only shapes.
public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// A JSON response with the given status and body.
    public static func json(status: Int, body: Data) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: body)
    }

    /// A 200 static asset with its own content-type. `Cache-Control: no-store`
    /// so a redeployed binary's UI is never served stale from a local cache.
    public static func asset(contentType: String, body: Data) -> HTTPResponse {
        HTTPResponse(
            status: 200,
            headers: ["Content-Type": contentType, "Cache-Control": "no-store"],
            body: body
        )
    }

    /// A 404 with a small JSON body.
    public static var notFound: HTTPResponse {
        HTTPResponse(status: 404, headers: ["Content-Type": "application/json"], body: Data(#"{"error":"not_found"}"#.utf8))
    }

    /// Serialize this response and write it to socket `fd`. `Content-Length` is
    /// computed from the body and overrides any caller-supplied value. Headers
    /// are emitted in a deterministic order (Content-Type, Content-Length, then
    /// the remainder sorted alphabetically), then `Connection: close` is always
    /// appended last. A caller-supplied `Connection` header is emitted in the
    /// sorted section and does not suppress the trailing `Connection: close`.
    public func send(fd: Int32) {
        var hdrs = headers
        hdrs["Content-Length"] = String(body.count)

        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        let priority = ["Content-Type", "Content-Length"]
        for key in priority {
            if let value = hdrs[key] { head += "\(key): \(value)\r\n" }
        }
        for key in hdrs.keys.sorted() where !priority.contains(key) {
            head += "\(key): \(hdrs[key]!)\r\n"
        }
        head += "Connection: close\r\n\r\n"

        var data = Data(head.utf8)
        data.append(body)
        POSIXSocket.sendAll(fd, data)
    }

    /// Reason phrase for the status codes this library emits.
    public static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        default:  return "OK"
        }
    }
}

// MARK: - SSEStream

/// A Server-Sent-Events stream over a connected socket fd. This type owns the
/// SSE wire framing — the `text/event-stream` response head and the `data: …`
/// frame encoding. The CONSUMER owns everything else: the stream's source, its
/// cadence, its lifetime, and closing the fd when done. moot-mgr drives it from
/// a store poll; the resident MCP transport drives it from JSON-RPC
/// notifications (P1b). Neither leaks into this type.
public struct SSEStream: Sendable {
    public let fd: Int32

    public init(fd: Int32) {
        self.fd = fd
    }

    /// Write the SSE response head. Call once, before any frame. Returns false if
    /// the peer is already gone (the caller should close and stop).
    @discardableResult
    public func writeHead() -> Bool {
        POSIXSocket.sendAll(fd, Self.responseHead)
    }

    /// Send one SSE `data:` frame carrying `payload`. Returns false if the write
    /// failed (peer hung up); the caller should stop the stream.
    @discardableResult
    public func send(_ payload: String) -> Bool {
        POSIXSocket.sendAll(fd, Data("data: \(payload)\n\n".utf8))
    }

    /// The fixed SSE response head: 200 + text/event-stream + no-cache +
    /// keep-alive.
    static let responseHead = Data(
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n".utf8
    )
}
