// LoopbackHTTPTests.swift
//
// Exercises the real socket paths of LoopbackHTTP over a connected socketpair:
// request parsing (incl. the per-listener body cap), buffered-response framing,
// and SSE framing. moot-mgr's own suite covers the end-to-end loopback server;
// these tests pin the extracted primitive's wire contract directly.

import Testing
import Foundation
@testable import LoopbackHTTP

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

private struct SocketPair {
    let a: Int32  // write test bytes here
    let b: Int32  // the code-under-test reads/writes here

    init() {
        var fds: [Int32] = [0, 0]
        let rc = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        precondition(rc == 0, "socketpair failed: \(errno)")
        a = fds[0]
        b = fds[1]
    }

    func closeAll() { close(a); close(b) }
}

/// Drain a fd to EOF into a String (UTF-8). The peer must be closed for EOF.
private func readAllUTF8(_ fd: Int32) -> String {
    var out = Data()
    while let chunk = POSIXSocket.recv(fd, max: 4096), !chunk.isEmpty {
        out.append(chunk)
    }
    return String(data: out, encoding: .utf8) ?? ""
}

@Suite("LoopbackHTTP wire contract")
struct LoopbackHTTPTests {

    @Test("parses a GET with query, headers, and the convenience accessors")
    func parseGet() {
        let pair = SocketPair()
        defer { pair.closeAll() }
        let raw = "GET /api/events?stream=1 HTTP/1.1\r\n" +
            "Host: 127.0.0.1\r\n" +
            "Accept: text/event-stream\r\n" +
            "Origin: http://localhost:7077\r\n" +
            "Authorization: Bearer abc123\r\n\r\n"
        _ = POSIXSocket.sendAll(pair.a, Data(raw.utf8))
        close(pair.a)  // EOF so read() terminates if it needs more

        let req = HTTPRequest.read(fd: pair.b)
        #expect(req != nil)
        #expect(req?.method == "GET")
        #expect(req?.path == "/api/events")
        #expect(req?.query == "stream=1")
        #expect(req?.wantsEventStream == true)
        #expect(req?.origin == "http://localhost:7077")
        #expect(req?.bearerToken == "abc123")
    }

    @Test("reads a POST body up to Content-Length")
    func parsePostBody() {
        let pair = SocketPair()
        defer { pair.closeAll() }
        let body = #"{"seconds":3600}"#
        let raw = "POST /api/control/retention HTTP/1.1\r\n" +
            "Content-Length: \(body.utf8.count)\r\n\r\n" + body
        _ = POSIXSocket.sendAll(pair.a, Data(raw.utf8))
        close(pair.a)

        let req = HTTPRequest.read(fd: pair.b)
        #expect(req?.method == "POST")
        #expect(req?.path == "/api/control/retention")
        #expect(req.map { String(data: $0.body, encoding: .utf8) } == body)
    }

    @Test("the per-listener body cap bounds the body read")
    func bodyCapTruncates() {
        let pair = SocketPair()
        defer { pair.closeAll() }
        let body = String(repeating: "x", count: 100)
        let raw = "POST /big HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
        _ = POSIXSocket.sendAll(pair.a, Data(raw.utf8))
        close(pair.a)

        // Cap below the declared length: the body is bounded to the cap.
        let req = HTTPRequest.read(fd: pair.b, maxBodyBytes: 10)
        #expect(req?.body.count == 10)
    }

    @Test("buffered response writes status line, headers, and body")
    func responseSend() {
        let pair = SocketPair()
        defer { close(pair.b) }
        let resp = HTTPResponse.json(status: 200, body: Data(#"{"ok":true}"#.utf8))
        resp.send(fd: pair.a)
        close(pair.a)  // EOF for readAll

        let wire = readAllUTF8(pair.b)
        #expect(wire.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(wire.contains("Content-Type: application/json\r\n"))
        #expect(wire.contains("Content-Length: 11\r\n"))
        #expect(wire.contains("Connection: close\r\n"))
        #expect(wire.hasSuffix("\r\n\r\n{\"ok\":true}"))
    }

    @Test("notFound is a 404 JSON response")
    func responseNotFound() {
        let pair = SocketPair()
        defer { close(pair.b) }
        HTTPResponse.notFound.send(fd: pair.a)
        close(pair.a)

        let wire = readAllUTF8(pair.b)
        #expect(wire.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
        #expect(wire.contains(#"{"error":"not_found"}"#))
    }

    @Test("SSE stream writes the event-stream head then data frames")
    func sseFraming() {
        let pair = SocketPair()
        defer { close(pair.b) }
        let sse = SSEStream(fd: pair.a)
        #expect(sse.writeHead() == true)
        #expect(sse.send(#"{"e":1}"#) == true)
        close(pair.a)

        let wire = readAllUTF8(pair.b)
        #expect(wire.contains("Content-Type: text/event-stream\r\n"))
        #expect(wire.contains("Cache-Control: no-cache\r\n"))
        #expect(wire.contains("Connection: keep-alive\r\n"))
        #expect(wire.hasSuffix("data: {\"e\":1}\n\n"))
    }
}
