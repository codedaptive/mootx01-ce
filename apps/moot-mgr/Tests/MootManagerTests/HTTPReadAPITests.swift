// HTTPReadAPITests.swift
//
// P3 verify line: the loopback HTTP read-API returns the GUI-SPEC §10 payload
// shapes from a seeded ObserverSink store, binds 127.0.0.1 only, and gates the
// HTTP control surface behind a bearer token + Origin check.
//
// The tests drive the REAL server over a real loopback TCP connection (a tiny
// URLSession/raw-socket client), against a started ResidentHost backed by a
// temp SQLite store with caller-supplied timestamps — no mocks for the wire.

import Testing
import Foundation
import ObserverSink
@testable import MootManager

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// MARK: - Helpers

/// A fresh temp store URL per test.
private func makeTempStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("moot-mgr-http-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("stats.sqlite", isDirectory: false)
}

/// A fresh temp UDS path per test (short — UDS paths have a ~104-char limit).
private func makeTempSocketPath() -> String {
    "/tmp/mm-\(UUID().uuidString.prefix(8)).sock"
}

/// A valid 32-char control token.
private let testToken = "0123456789abcdef0123456789abcdef"

/// Start a ResidentHost on an OS-assigned port with a seeded store, returning
/// the host and the bound port. The seed runs against the host's owned store.
private func makeStartedHost(
    seed: (StatsStore) async throws -> Void = { _ in }
) async throws -> (host: ResidentHost, port: UInt16) {
    let cfg = ResidentHostConfig(
        manager: ManagerConfig(storeURL: makeTempStoreURL(), retentionWindow: 1000),
        httpPort: 0,                       // OS-assigned
        controlToken: testToken,
        controlSocketPath: makeTempSocketPath(),
        estatesDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-estates-\(UUID().uuidString)", isDirectory: true)
    )
    let host = ResidentHost(config: cfg, startInstant: Date(timeIntervalSince1970: 1000),
                            clock: { Date(timeIntervalSince1970: 2000) })
    try await host.start()
    let store = try await host.managerHandle().statsStore()
    try await seed(store)
    let port = await host.boundHTTPPort()
    return (host, port)
}

/// Issue an HTTP request over loopback and return (status, body string).
/// Minimal raw-socket-free client via URLSession against 127.0.0.1.
private func httpRequest(
    port: UInt16,
    method: String,
    path: String,
    headers: [String: String] = [:],
    body: Data? = nil
) async throws -> (status: Int, body: String) {
    var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    req.httpMethod = method
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    req.httpBody = body
    let (data, response) = try await URLSession.shared.data(for: req)
    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
    return (status, String(data: data, encoding: .utf8) ?? "")
}

// MARK: - Read endpoints

struct HTTPReadAPIReadTests {

    @Test("GET /api/server returns the server summary shape from a seeded store")
    func serverEndpoint() async throws {
        let (host, port) = try await makeStartedHost { store in
            try await store.setMonitoringEnabled(true)
            try await store.insertMetric(name: "m", value: 1, tags: [:], ts: 100, dropboxID: "d")
            try await store.insertEvent(kind: "capture", nounType: 1, rowID: UUID().uuidString,
                                        estate: "estate-x", ts: 200, dropboxID: "d")
        }
        defer { Task { await host.stop() } }

        let (status, body) = try await httpRequest(port: port, method: "GET", path: "/api/server")
        #expect(status == 200)
        let payload = try JSONDecoder().decode(ServerPayload.self, from: Data(body.utf8))
        #expect(payload.monitoringEnabled == true)
        #expect(payload.totalMetrics == 1)
        #expect(payload.totalEvents == 1)
        #expect(payload.estateCount == 1)
        // uptime = clock(2000) - startInstant(1000) = 1000s.
        #expect(payload.uptimeSeconds == 1000)
        #expect(payload.storeSizeBytes > 0)
    }

    @Test("GET /api/estates returns per-estate event rollups, sorted")
    func estatesEndpoint() async throws {
        let (host, port) = try await makeStartedHost { store in
            try await store.insertEvent(kind: "capture", nounType: 1, rowID: UUID().uuidString,
                                        estate: "beta", ts: 100, dropboxID: "d")
            try await store.insertEvent(kind: "think", nounType: 2, rowID: UUID().uuidString,
                                        estate: "alpha", ts: 200, dropboxID: "d")
            try await store.insertEvent(kind: "think", nounType: 2, rowID: UUID().uuidString,
                                        estate: "alpha", ts: 300, dropboxID: "d")
        }
        defer { Task { await host.stop() } }

        let (status, body) = try await httpRequest(port: port, method: "GET", path: "/api/estates")
        #expect(status == 200)
        let payload = try JSONDecoder().decode(EstatesPayload.self, from: Data(body.utf8))
        #expect(payload.estates.count == 2)
        // Sorted by id: alpha, beta.
        #expect(payload.estates[0].id == "alpha")
        #expect(payload.estates[0].eventCount == 2)
        #expect(payload.estates[1].id == "beta")
        #expect(payload.estates[1].eventCount == 1)
        // lastEventTs present for alpha (newest = ts 300).
        #expect(payload.estates[0].lastEventTs?.hasPrefix("1970-01-01T00:05:00") == true)
    }

    @Test("GET /api/events returns recent events newest-first")
    func eventsEndpoint() async throws {
        let (host, port) = try await makeStartedHost { store in
            for i in 0..<3 {
                try await store.insertEvent(kind: "capture", nounType: i, rowID: UUID().uuidString,
                                            estate: "e", ts: Double(100 + i), dropboxID: "d")
            }
        }
        defer { Task { await host.stop() } }

        let (status, body) = try await httpRequest(port: port, method: "GET", path: "/api/events")
        #expect(status == 200)
        let payload = try JSONDecoder().decode(EventsPayload.self, from: Data(body.utf8))
        #expect(payload.events.count == 3)
        // Newest first: ts=102 nounType=2 leads.
        #expect(payload.events[0].nounType == 2)
        #expect(payload.events[2].nounType == 0)
    }

    @Test("GET /api/config returns the monitoring config shape")
    func configEndpoint() async throws {
        let (host, port) = try await makeStartedHost { store in
            try await store.setMonitoringEnabled(true)
        }
        defer { Task { await host.stop() } }

        let (status, body) = try await httpRequest(port: port, method: "GET", path: "/api/config")
        #expect(status == 200)
        let payload = try JSONDecoder().decode(ConfigPayload.self, from: Data(body.utf8))
        #expect(payload.monitoringEnabled == true)
        #expect(payload.retentionSeconds == 1000)        // configured window
        // No retention pass run yet → epoch-zero sentinel.
        #expect(payload.retentionCutoff == "1970-01-01T00:00:00.000Z")
    }

    @Test("Unknown path returns 404")
    func unknownPath() async throws {
        let (host, port) = try await makeStartedHost()
        defer { Task { await host.stop() } }
        let (status, _) = try await httpRequest(port: port, method: "GET", path: "/api/nope")
        #expect(status == 404)
    }
}

// MARK: - Auth / security

struct HTTPReadAPIAuthTests {

    @Test("POST control without a token is rejected 401")
    func controlMissingTokenRejected() async throws {
        let (host, port) = try await makeStartedHost()
        defer { Task { await host.stop() } }
        let (status, _) = try await httpRequest(
            port: port, method: "POST", path: "/api/control/monitoring/on")
        #expect(status == 401)
    }

    @Test("POST control with a short token is rejected 401")
    func controlShortTokenRejected() async throws {
        let (host, port) = try await makeStartedHost()
        defer { Task { await host.stop() } }
        let (status, _) = try await httpRequest(
            port: port, method: "POST", path: "/api/control/monitoring/on",
            headers: ["Authorization": "Bearer short"])
        #expect(status == 401)
    }

    @Test("POST control with a bad token is rejected 401")
    func controlBadTokenRejected() async throws {
        let (host, port) = try await makeStartedHost()
        defer { Task { await host.stop() } }
        let bad = String(repeating: "x", count: testToken.count)
        let (status, _) = try await httpRequest(
            port: port, method: "POST", path: "/api/control/monitoring/on",
            headers: ["Authorization": "Bearer \(bad)"])
        #expect(status == 401)
    }

    @Test("POST control with a cross-origin Origin is rejected 403")
    func controlCrossOriginRejected() async throws {
        let (host, port) = try await makeStartedHost()
        defer { Task { await host.stop() } }
        // Origin check runs BEFORE the token check, so even a valid token is
        // rejected when the Origin is cross-origin (CSRF guard).
        let (status, _) = try await httpRequest(
            port: port, method: "POST", path: "/api/control/monitoring/on",
            headers: ["Authorization": "Bearer \(testToken)", "Origin": "http://evil.example.com"])
        #expect(status == 403)
    }

    @Test("POST control with a valid token + loopback Origin enables monitoring")
    func controlValidTokenApplies() async throws {
        let (host, port) = try await makeStartedHost()
        defer { Task { await host.stop() } }

        let (status, body) = try await httpRequest(
            port: port, method: "POST", path: "/api/control/monitoring/on",
            headers: ["Authorization": "Bearer \(testToken)",
                      "Origin": "http://127.0.0.1:\(port)"])
        #expect(status == 200)
        #expect(body.contains("ON"))

        // Reflected in /api/config.
        let (_, cfgBody) = try await httpRequest(port: port, method: "GET", path: "/api/config")
        let cfg = try JSONDecoder().decode(ConfigPayload.self, from: Data(cfgBody.utf8))
        #expect(cfg.monitoringEnabled == true)
    }
}

// MARK: - SSE live tail

struct HTTPReadAPISSETests {

    @Test("GET /api/events?stream=1 streams events as SSE frames")
    func sseLiveTail() async throws {
        let (host, port) = try await makeStartedHost { store in
            // Seed one event so the first poll has something to emit.
            try await store.insertEvent(kind: "capture", nounType: 7, rowID: UUID().uuidString,
                                        estate: "e-sse", ts: 100, dropboxID: "d")
        }
        defer { Task { await host.stop() } }

        // Open a raw loopback TCP connection and request the SSE stream, then
        // read frames until we see a data line (or time out). Blocking socket
        // I/O is wrapped in a detached task.
        let frame = await Task.detached(priority: .userInitiated) { () -> String in
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return "" }
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
            guard connected == 0 else { return "" }

            let req = "GET /api/events?stream=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept: text/event-stream\r\n\r\n"
            _ = Array(req.utf8).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }

            var acc = ""
            var buf = [UInt8](repeating: 0, count: 4096)
            // Read a few chunks; the first poll fires ~immediately and emits the
            // seeded event as a `data:` line after the SSE response head.
            for _ in 0..<5 {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                acc += String(bytes: buf[0..<n], encoding: .utf8) ?? ""
                if acc.contains("data:") { break }
            }
            return acc
        }.value

        #expect(frame.contains("text/event-stream"))
        #expect(frame.contains("data:"))
        // The seeded event's nounType=7 appears in the streamed JSON.
        #expect(frame.contains("\"nounType\":7"))
    }
}

// MARK: - Pure auth-helper unit tests (no socket)

struct HTTPAuthHelperTests {

    @Test("constant-time compare distinguishes equal/unequal")
    func constantTimeEqual() {
        #expect(HTTPReadAPI.constantTimeEqual("abcdef", "abcdef"))
        #expect(!HTTPReadAPI.constantTimeEqual("abcdef", "abcdeg"))
        #expect(!HTTPReadAPI.constantTimeEqual("abc", "abcd"))
    }

    @Test("Origin allow-list accepts loopback/absent, rejects cross-origin")
    func originAllowList() {
        #expect(HTTPReadAPI.isOriginAllowed(nil))
        #expect(HTTPReadAPI.isOriginAllowed(""))
        #expect(HTTPReadAPI.isOriginAllowed("http://127.0.0.1:8080"))
        #expect(HTTPReadAPI.isOriginAllowed("http://localhost:9000"))
        #expect(HTTPReadAPI.isOriginAllowed("http://[::1]:1234"))
        #expect(!HTTPReadAPI.isOriginAllowed("http://evil.example.com"))
        #expect(!HTTPReadAPI.isOriginAllowed("http://192.168.1.5"))
    }
}
