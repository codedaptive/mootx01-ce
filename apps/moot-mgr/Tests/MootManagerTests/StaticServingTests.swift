// StaticServingTests.swift
//
// P4 verify line: the resident host serves the read-plane web dashboard from
// the loopback HTTP listener — `GET /` returns the index HTML, each asset is
// served with the correct content-type, unknown asset paths 404 safely, and the
// fields each dashboard view binds to are present in the corresponding live
// /api/* payload (so the UI never binds to a field the API does not serve).
//
// Static assets are read-only and ride the same 127.0.0.1-only listener as the
// JSON read endpoints (no new socket, no new bind) — the security posture is
// unchanged from P3.

import Testing
import Foundation
import ObserverSink
@testable import MootManager

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// MARK: - Helpers (a started host on an OS-assigned loopback port)

private func makeTempStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("moot-mgr-static-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("stats.sqlite", isDirectory: false)
}

private func makeTempSocketPath() -> String {
    "/tmp/mm-st-\(UUID().uuidString.prefix(8)).sock"
}

private let stToken = "0123456789abcdef0123456789abcdef"

private func makeStartedHost(
    seed: (StatsStore) async throws -> Void = { _ in }
) async throws -> (host: ResidentHost, port: UInt16) {
    let cfg = ResidentHostConfig(
        manager: ManagerConfig(storeURL: makeTempStoreURL(), retentionWindow: 1000),
        httpPort: 0,
        controlToken: stToken,
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

/// Issue a GET over loopback, returning status, the `Content-Type` header, and
/// the body string. Uses URLSession against 127.0.0.1 (no raw socket).
private func httpGET(port: UInt16, path: String) async throws
    -> (status: Int, contentType: String?, body: String)
{
    let req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    let (data, response) = try await URLSession.shared.data(for: req)
    let http = response as? HTTPURLResponse
    let status = http?.statusCode ?? -1
    let ctype = http?.value(forHTTPHeaderField: "Content-Type")
    return (status, ctype, String(data: data, encoding: .utf8) ?? "")
}

// MARK: - Static asset serving

struct StaticServingTests {

    @Test("GET / serves the dashboard index HTML")
    func indexServed() async throws {
        let (host, port) = try await makeStartedHost()
        defer { Task { await host.stop() } }

        let (status, ctype, body) = try await httpGET(port: port, path: "/")
        #expect(status == 200)
        #expect(ctype?.hasPrefix("text/html") == true)
        #expect(body.contains("<!DOCTYPE html>"))
        // The dashboard wires the read views and the API'd assets.
        #expect(body.contains("READ CONSOLE"))
        #expect(body.contains("/app.css"))
        #expect(body.contains("/app.js"))
    }

    @Test("GET /index.html serves the same index HTML")
    func indexAliasServed() async throws {
        let (host, port) = try await makeStartedHost()
        defer { Task { await host.stop() } }
        let (status, ctype, body) = try await httpGET(port: port, path: "/index.html")
        #expect(status == 200)
        #expect(ctype?.hasPrefix("text/html") == true)
        #expect(body.contains("<!DOCTYPE html>"))
    }

    @Test("GET /app.css serves CSS with the CSS content-type")
    func cssServed() async throws {
        let (host, port) = try await makeStartedHost()
        defer { Task { await host.stop() } }
        let (status, ctype, body) = try await httpGET(port: port, path: "/app.css")
        #expect(status == 200)
        #expect(ctype?.hasPrefix("text/css") == true)
        #expect(body.contains(":root"))
    }

    @Test("GET /app.js serves JS with the JS content-type")
    func jsServed() async throws {
        let (host, port) = try await makeStartedHost()
        defer { Task { await host.stop() } }
        let (status, ctype, body) = try await httpGET(port: port, path: "/app.js")
        #expect(status == 200)
        #expect(ctype?.hasPrefix("text/javascript") == true)
        // The dashboard issues only reads; assert it does not POST control.
        #expect(body.contains("/api/server"))
        #expect(!body.contains("/api/control"))
    }

    @Test("Unknown static path returns 404 (no path traversal)")
    func unknownStaticPath404() async throws {
        let (host, port) = try await makeStartedHost()
        defer { Task { await host.stop() } }
        for path in ["/nope.html", "/../Package.swift", "/app.js.bak", "/assets/secret"] {
            let (status, _, _) = try await httpGET(port: port, path: path)
            #expect(status == 404, "expected 404 for \(path)")
        }
    }

    @Test("Asset allow-list maps exactly the dashboard paths and nothing else")
    func allowListIsExact() {
        #expect(StaticAssets.asset(for: "/") != nil)
        #expect(StaticAssets.asset(for: "/index.html") != nil)
        #expect(StaticAssets.asset(for: "/app.css") != nil)
        #expect(StaticAssets.asset(for: "/app.js") != nil)
        // P5 added the vendored Topology renderer to the fixed allow-list.
        #expect(StaticAssets.asset(for: "/sigma.js") != nil)
        // Anything off the list — including traversal attempts — resolves to nil.
        #expect(StaticAssets.asset(for: "/../StaticAssets.swift") == nil)
        #expect(StaticAssets.asset(for: "/app.css/../app.js") == nil)
        #expect(StaticAssets.asset(for: "/api/server") == nil)
        #expect(StaticAssets.asset(for: "") == nil)
    }
}

// MARK: - View ↔ payload binding contract

/// Each dashboard view binds to a set of fields on its endpoint's payload. If a
/// view's bound field disappears from the API, the dashboard would silently
/// render blanks — so we assert presence here. JSON is decoded as a dictionary
/// (the wire shape the JS sees) rather than the typed struct, to test the exact
/// keys the browser reads.
struct ViewBindingContractTests {

    private func jsonObject(port: UInt16, path: String) async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(
            for: URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    @Test("Overview binds fields present in /api/server")
    func overviewFields() async throws {
        let (host, port) = try await makeStartedHost { store in
            try await store.insertEvent(kind: "capture", nounType: 1, rowID: UUID().uuidString,
                                        estate: "e", ts: 100, dropboxID: "d")
        }
        defer { Task { await host.stop() } }
        let obj = try await jsonObject(port: port, path: "/api/server")
        for key in ["monitoringEnabled", "uptimeSeconds", "estateCount",
                    "totalMetrics", "totalEvents", "storeSizeBytes"] {
            #expect(obj[key] != nil, "missing /api/server field: \(key)")
        }
    }

    @Test("Estates binds fields present in /api/estates rows")
    func estatesFields() async throws {
        let (host, port) = try await makeStartedHost { store in
            try await store.insertEvent(kind: "think", nounType: 2, rowID: UUID().uuidString,
                                        estate: "alpha", ts: 200, dropboxID: "d")
        }
        defer { Task { await host.stop() } }
        let obj = try await jsonObject(port: port, path: "/api/estates")
        let estates = obj["estates"] as? [[String: Any]] ?? []
        #expect(!estates.isEmpty)
        let row = estates[0]
        for key in ["id", "eventCount", "lastEventTs"] {
            #expect(row.keys.contains(key), "missing /api/estates row field: \(key)")
        }
    }

    @Test("Activity + Pipeline bind fields present in /api/events rows")
    func eventsFields() async throws {
        let (host, port) = try await makeStartedHost { store in
            try await store.insertEvent(kind: "capture", nounType: 7, rowID: UUID().uuidString,
                                        estate: "e", ts: 100, dropboxID: "d")
        }
        defer { Task { await host.stop() } }
        let obj = try await jsonObject(port: port, path: "/api/events")
        let events = obj["events"] as? [[String: Any]] ?? []
        #expect(!events.isEmpty)
        let row = events[0]
        for key in ["ts", "kind", "nounType", "estate", "dropbox"] {
            #expect(row.keys.contains(key), "missing /api/events row field: \(key)")
        }
    }

    @Test("Configuration binds fields present in /api/config")
    func configFields() async throws {
        let (host, port) = try await makeStartedHost()
        defer { Task { await host.stop() } }
        let obj = try await jsonObject(port: port, path: "/api/config")
        for key in ["monitoringEnabled", "retentionSeconds", "retentionCutoff"] {
            #expect(obj[key] != nil, "missing /api/config field: \(key)")
        }
    }
}
