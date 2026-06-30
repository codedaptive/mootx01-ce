// LoopbackHTTPTestClient.swift
//
// A raw-socket HTTP/1.1 client for the moot-mgr loopback test suites.
//
// WHY NOT URLSession: on the `macos-26` GitHub Actions runner, every
// `URLSession.shared` request to `http://127.0.0.1:<port>` hangs and fails with
// `NSURLErrorTimedOut` (-1001) — a CFNetwork/proxy quirk of that runner image —
// even though the loopback server is up. A raw socket to the same port works:
// the SSE test in HTTPReadAPITests (which already uses a raw socket) PASSED in
// CI while every URLSession-based test timed out. The tests pass locally with
// URLSession, so this is a runner-only failure of URLSession's host networking,
// not a product bug. Routing the loopback test client through a BSD socket
// removes the dependency on URLSession's proxy/connectivity configuration.
//
// WHY GCD, NOT Task.detached: the blocking socket syscalls must NOT run on the
// Swift cooperative thread pool. `Task.detached` uses that pool, and under
// parallel test execution (~20 suites at once) blocking it starves the same
// pool the server's async accept/serve work runs on — connect() succeeds but
// the request is never serviced, so the read returns an empty response. Running
// the blocking exchange on a GCD global-queue thread keeps the cooperative pool
// free, so the suites stay green in parallel.
//
// moot-mgr's `HTTPReadAPI` closes the connection after each response
// (`send(fd:)` then `close(fd)`), so writing `Connection: close` and reading to
// EOF yields the complete response; an `SO_RCVTIMEO` safety net keeps a
// misbehaving server from hanging the worker thread.

import Foundation

/// Result of a loopback HTTP request: status code, response headers (keys
/// lowercased for case-insensitive lookup), and the body as a UTF-8 string.
struct LoopbackHTTPResponse {
    let status: Int
    let headers: [String: String]
    let body: String
}

private enum LoopbackHTTPError: Error { case socketCreate, connect }

/// Perform one HTTP/1.1 request against a loopback server on `127.0.0.1:<port>`
/// using a raw socket (no URLSession — see file header for why). The blocking
/// socket I/O runs on a GCD thread so it never blocks the cooperative pool.
func loopbackHTTP(
    port: UInt16,
    method: String = "GET",
    path: String,
    headers: [String: String] = [:],
    body: Data? = nil
) async throws -> LoopbackHTTPResponse {
    let bodyData = body ?? Data()

    // Build the request once. `Connection: close` → the server closes the
    // socket after the response, so the read loop ends on EOF and the body is
    // known to be complete.
    var head = "\(method) \(path) HTTP/1.1\r\n"
    head += "Host: 127.0.0.1:\(port)\r\n"
    head += "Connection: close\r\n"
    for (k, v) in headers { head += "\(k): \(v)\r\n" }
    head += "Content-Length: \(bodyData.count)\r\n\r\n"
    var request = Array(head.utf8)
    request.append(contentsOf: bodyData)

    return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<LoopbackHTTPResponse, Error>) in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                cont.resume(returning: try blockingLoopbackExchange(port: port, request: request))
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}

/// Synchronous connect → write → read-to-EOF → parse. Runs on a GCD worker.
private func blockingLoopbackExchange(port: UInt16, request: [UInt8]) throws -> LoopbackHTTPResponse {
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian  // 127.0.0.1

    // Connect with bounded retry. `makeStartedHost` can return the port a moment
    // before the accept loop is listening; a single connect() would then race
    // and fail with ECONNREFUSED. ~3s ceiling (300 × 10ms).
    var fd: Int32 = -1
    for _ in 0..<300 {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { throw LoopbackHTTPError.socketCreate }
        let ok = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(s, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if ok == 0 { fd = s; break }
        close(s)
        usleep(10_000)  // 10ms between attempts
    }
    guard fd >= 0 else { throw LoopbackHTTPError.connect }
    defer { close(fd) }

    // Generous receive timeout (90s) — a backstop against a server that never
    // closes, NOT a tight per-request bound. On the macos-26 CI runner, loopback
    // can take ~60s to deliver the first byte (the raw-socket SSE test passes
    // only by waiting it out at ~62s; a 5s timeout fired empty before the slow
    // response arrived, producing the spurious status=-1 failures). 90s leaves
    // ample margin over the observed latency while still bounding a truly stuck
    // read. Locally the response is immediate, so this never delays a real run.
    var tv = timeval(tv_sec: 90, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    request.withUnsafeBytes { raw in
        guard var ptr = raw.baseAddress else { return }
        var remaining = raw.count
        while remaining > 0 {
            let n = write(fd, ptr, remaining)
            if n <= 0 { break }
            ptr = ptr.advanced(by: n)
            remaining -= n
        }
    }

    var acc = [UInt8]()
    var buf = [UInt8](repeating: 0, count: 8192)
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }  // EOF (server closed) or recv timeout
        acc.append(contentsOf: buf[0..<n])
    }

    return parseLoopbackResponse(acc)
}

/// Parse a raw HTTP/1.1 response into status line, headers, and body.
private func parseLoopbackResponse(_ bytes: [UInt8]) -> LoopbackHTTPResponse {
    // Split headers from body at the first CRLFCRLF.
    let sep: [UInt8] = [13, 10, 13, 10]
    var headerEnd = -1
    if bytes.count >= 4 {
        for i in 0...(bytes.count - 4) where Array(bytes[i..<i + 4]) == sep {
            headerEnd = i
            break
        }
    }
    let headBytes = headerEnd >= 0 ? Array(bytes[0..<headerEnd]) : bytes
    let bodyBytes = headerEnd >= 0 ? Array(bytes[(headerEnd + 4)...]) : []
    let headStr = String(bytes: headBytes, encoding: .utf8) ?? ""
    let lines = headStr.components(separatedBy: "\r\n")

    // Status line: "HTTP/1.1 200 OK" → 200.
    var status = -1
    if let first = lines.first {
        let parts = first.split(separator: " ")
        if parts.count >= 2 { status = Int(parts[1]) ?? -1 }
    }

    // Header lines: "Key: Value" → headers[key.lowercased()] = value.
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        headers[key] = val
    }

    let body = String(bytes: bodyBytes, encoding: .utf8) ?? ""
    return LoopbackHTTPResponse(status: status, headers: headers, body: body)
}
