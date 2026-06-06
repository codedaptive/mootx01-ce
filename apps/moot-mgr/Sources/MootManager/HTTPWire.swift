// HTTPWire.swift
//
// A minimal HTTP/1.1 request reader and response writer over a POSIX socket fd,
// for the moot-mgr loopback read-API. NO external HTTP package (no SwiftNIO) —
// this is the small, purpose-built parser the zero-dependency rule requires.
//
// Scope is intentionally narrow: it parses a request line + headers + an
// optional Content-Length body, and writes a single response. It is NOT a
// general-purpose HTTP server — it handles exactly the methods/shapes the
// read-API uses (GET snapshots, GET SSE, POST control with a small JSON body).

import Foundation

// MARK: - HTTPRequest

/// A parsed HTTP/1.1 request: method, path, headers, and an optional body.
struct HTTPRequest: Sendable {
    let method: String
    /// The path WITHOUT the query string (query is parsed into `query`).
    let path: String
    /// Raw query string after '?', or "" if none.
    let query: String
    let headers: [String: String]
    let body: Data

    /// The Bearer token from the Authorization header, or nil.
    var bearerToken: String? {
        guard let auth = headers["authorization"] else { return nil }
        let prefix = "bearer "
        guard auth.lowercased().hasPrefix(prefix) else { return nil }
        return String(auth.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    /// The Origin header value, or nil.
    var origin: String? { headers["origin"] }

    /// Whether the client asked for the SSE event stream (Accept header or
    /// ?stream=1 query flag).
    var wantsEventStream: Bool {
        if let accept = headers["accept"], accept.contains("text/event-stream") { return true }
        return query.contains("stream=1")
    }

    /// Read and parse one request from socket `fd`.
    ///
    /// Reads until the header terminator (CRLF CRLF), then reads exactly
    /// Content-Length more bytes for the body if present. Returns nil on a
    /// malformed request or socket error.
    static func read(fd: Int32) -> HTTPRequest? {
        var buffer = Data()
        // Cap the header size to guard against an unbounded read from a
        // misbehaving (loopback-but-hostile) peer.
        let headerCap = 64 * 1024
        while true {
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                return parse(buffer: buffer, headerEnd: range.upperBound, fd: fd)
            }
            if buffer.count > headerCap { return nil }
            guard let chunk = POSIXSocket.recv(fd, max: 16 * 1024), !chunk.isEmpty else {
                return nil
            }
            buffer.append(chunk)
        }
    }

    /// Parse the buffered header block, reading the body if Content-Length says so.
    private static func parse(buffer: Data, headerEnd: Data.Index, fd: Int32) -> HTTPRequest? {
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
        // after the header terminator counts).
        var body = Data(buffer[headerEnd...])
        if let lenStr = headers["content-length"], let len = Int(lenStr), len > 0 {
            // Cap the body too — control payloads are tiny JSON objects.
            let bodyCap = 64 * 1024
            let want = min(len, bodyCap)
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

/// A response the read-API can send: a buffered JSON/status response, a 404,
/// or the held-open SSE event stream.
enum HTTPResponse: Sendable {
    /// A complete buffered response with a status code and JSON body.
    case json(status: Int, body: Data)
    /// 404 Not Found.
    case notFound
    /// The SSE live tail — the API holds the connection open and streams.
    case eventStream

    /// Send this response on socket `fd`. For `.eventStream`, returns without
    /// sending — the caller drives the streaming loop and owns the fd lifetime.
    /// Returns `true` if the caller should keep the connection open (SSE).
    func send(fd: Int32) -> Bool {
        switch self {
        case let .json(status, body):
            POSIXSocket.sendAll(fd, Self.head(status: status, contentType: "application/json", length: body.count) + body)
            return false
        case .notFound:
            let body = Data(#"{"error":"not_found"}"#.utf8)
            POSIXSocket.sendAll(fd, Self.head(status: 404, contentType: "application/json", length: body.count) + body)
            return false
        case .eventStream:
            return true
        }
    }

    /// Build an HTTP/1.1 response head (status line + standard headers).
    static func head(status: Int, contentType: String, length: Int) -> Data {
        let reason = Self.reason(status)
        let head = """
        HTTP/1.1 \(status) \(reason)\r
        Content-Type: \(contentType)\r
        Content-Length: \(length)\r
        Connection: close\r
        \r

        """
        return Data(head.utf8)
    }

    /// Reason phrase for the status codes this API emits.
    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default:  return "OK"
        }
    }
}
