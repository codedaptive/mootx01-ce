// ReviewPaneTests.swift
//
// Part 1 verify: handler test that GET /api/review surfaces valid ReviewPayload
// fields from the daemon's ObserverSink StatsStore. Tests an empty-estate host
// (no events seeded) to confirm the shape contract, then a seeded host to
// confirm live counts propagate.
//
// Uses the same makeStartedHost / loopbackHTTP pattern as HTTPReadAPITests.

import Testing
import Foundation
import ObserverSink
@testable import MootManager

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// MARK: - Test helpers

private func makeTempStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("moot-mgr-review-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("stats.sqlite", isDirectory: false)
}

private func makeTempSocketPath() -> String {
    "/tmp/mm-rv-\(UUID().uuidString.prefix(8)).sock"
}

private let rvToken = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4"

private func makeStartedHost(
    seed: (StatsStore) async throws -> Void = { _ in }
) async throws -> (host: ResidentHost, port: UInt16) {
    let cfg = ResidentHostConfig(
        manager: ManagerConfig(storeURL: makeTempStoreURL(), retentionWindow: 1000),
        httpPort: 0,
        controlToken: rvToken,
        controlSocketPath: makeTempSocketPath(),
        estatesDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-est-\(UUID().uuidString)", isDirectory: true)
    )
    let host = ResidentHost(config: cfg, startInstant: Date(timeIntervalSince1970: 1000),
                            clock: { Date(timeIntervalSince1970: 2000) })
    try await host.start()
    let store = try await host.managerHandle().statsStore()
    try await seed(store)
    let port = await host.boundHTTPPort()
    return (host, port)
}

private func httpGET(port: UInt16, path: String) async throws
    -> (status: Int, contentType: String?, body: String)
{
    let r = try await loopbackHTTP(port: port, path: path)
    return (r.status, r.headers["content-type"], r.body)
}

// MARK: - ReviewPaneTests

@Suite struct ReviewPaneTests {

    @Test("GET /api/review returns 200 with JSON content-type")
    func reviewEndpointReturns200() async throws {
        let (host, port) = try await makeStartedHost()
        defer { Task { await host.stop() } }

        let (status, ctype, _) = try await httpGET(port: port, path: "/api/review")
        #expect(status == 200)
        #expect(ctype?.hasPrefix("application/json") == true)
    }

    @Test("GET /api/review on empty store returns valid ReviewPayload shape")
    func reviewEmptyStoreShape() async throws {
        let (host, port) = try await makeStartedHost()
        defer { Task { await host.stop() } }

        let (status, _, body) = try await httpGET(port: port, path: "/api/review")
        #expect(status == 200)

        // Confirm the four required fields are present in the JSON.
        let data = Data(body.utf8)
        let obj = try #require(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["pending"] != nil, "missing pending field")
        #expect(obj["estateCount"] != nil, "missing estateCount field")
        #expect(obj["captureCount"] != nil, "missing captureCount field")
        #expect(obj["recentEvents"] != nil, "missing recentEvents field")
    }

    @Test("GET /api/review empty store → estateCount=0, captureCount=0, recentEvents=[]")
    func reviewEmptyStoreCounts() async throws {
        let (host, port) = try await makeStartedHost()
        defer { Task { await host.stop() } }

        let (_, _, body) = try await httpGET(port: port, path: "/api/review")
        let data = Data(body.utf8)
        let obj = try #require(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        let estateCount = try #require(obj["estateCount"] as? Int)
        let captureCount = try #require(obj["captureCount"] as? Int)
        let events = try #require(obj["recentEvents"] as? [Any])
        #expect(estateCount == 0)
        #expect(captureCount == 0)
        #expect(events.isEmpty)
    }

    @Test("GET /api/review reflects seeded capture events in captureCount")
    func reviewReflectsSeedEvents() async throws {
        let estateName = "test-estate-\(UUID().uuidString.prefix(6))"
        let (host, port) = try await makeStartedHost { store in
            // Plant two capture events from one estate.
            try await store.insertEvent(
                kind: "capture",
                nounType: 1,
                rowID: UUID().uuidString,
                estate: estateName,
                ts: 1_500,
                dropboxID: "test-dropbox"
            )
            try await store.insertEvent(
                kind: "capture",
                nounType: 1,
                rowID: UUID().uuidString,
                estate: estateName,
                ts: 1_600,
                dropboxID: "test-dropbox"
            )
        }
        defer { Task { await host.stop() } }

        let (status, _, body) = try await httpGET(port: port, path: "/api/review")
        #expect(status == 200)

        let data = Data(body.utf8)
        let obj = try #require(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        let estateCount = try #require(obj["estateCount"] as? Int)
        let captureCount = try #require(obj["captureCount"] as? Int)
        let events = try #require(obj["recentEvents"] as? [Any])
        #expect(estateCount == 1, "expected one distinct estate")
        #expect(captureCount == 2, "expected two capture events")
        #expect(!events.isEmpty, "expected at least one event in recentEvents")
    }
}
