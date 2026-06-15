// ServerPayloadMetricsTests.swift
//
// Verifies that serverPayload() returns non-null metric fields when the
// corresponding server.* and substrate.kernel.backend_selected samples exist
// in the store, and returns nil for all metric fields when the store is empty.
// Part of the TELEMETRY-SM mission verify line.
//
// Also verifies (HOTFIX-HF1): serverPayload().totalMetrics matches countMetrics()
// (i.e. the payload now uses COUNT(*) not a full-row scan).
//
// Rows are inserted directly via StatsStore.insertMetric so the test is
// synchronous — PersistenceStatsSink dispatches each write as an unstructured
// Task and those Tasks are not awaited, so going through Intellectus would
// create a race between the background inserts and the serverPayload() query.

import Testing
import Foundation
import ObserverSink
@testable import MootManager

@Suite("ServerPayload metrics fields", .serialized)
struct ServerPayloadMetricsTests {

    private func makeStartedManager() async throws -> MootManager {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("server-payload-test-\(UUID().uuidString)", isDirectory: true)
        let url = tmp.appendingPathComponent("stats.sqlite", isDirectory: false)
        let config = ManagerConfig(storeURL: url, retentionWindow: 3600)
        let manager = MootManager(config: config)
        try await manager.start()
        return manager
    }

    @Test("serverPayload returns nil metric fields when store has no server samples")
    func serverPayloadNilWhenNoSamples() async throws {
        let manager = try await makeStartedManager()
        defer { Task { await manager.stop() } }

        let payload = try await manager.serverPayload(now: Date(), uptimeSeconds: 0)
        #expect(payload.rssMb == nil)
        #expect(payload.cpuUserMs == nil)
        #expect(payload.rpcCount == nil)
        #expect(payload.connections == nil)
        #expect(payload.protoVersion == nil)
        #expect(payload.kernelBackend == nil)
    }

    @Test("serverPayload returns non-null metric fields when server samples exist in store")
    func serverPayloadPopulatedFromStore() async throws {
        let manager = try await makeStartedManager()
        defer { Task { await manager.stop() } }

        let store = try await manager.statsStore()
        let dropboxID = "server-payload-test"
        let ts = 100_000.0

        // Insert rows directly so the test is synchronous (PersistenceStatsSink
        // dispatches each write as an unstructured Task that could race with the query).
        try await store.insertMetric(name: "server.rss_mb",    value: 128.5, tags: ["kit": "AriaResident"], ts: ts, dropboxID: dropboxID)
        try await store.insertMetric(name: "server.cpu_user_ms", value: 450.0, tags: ["kit": "AriaResident"], ts: ts, dropboxID: dropboxID)
        try await store.insertMetric(name: "server.rpc_count",  value: 17.0,  tags: ["kit": "AriaResident"], ts: ts, dropboxID: dropboxID)
        try await store.insertMetric(name: "server.connections", value: 3.0,  tags: ["kit": "AriaResident"], ts: ts, dropboxID: dropboxID)
        try await store.insertMetric(name: "server.proto_version", value: 1.0,
                                     tags: ["kit": "AriaResident", "version": "2025-11-25"], ts: ts, dropboxID: dropboxID)
        try await store.insertMetric(name: "substrate.kernel.backend_selected", value: 1.0,
                                     tags: ["kit": "AriaResident", "backend": "simd"], ts: ts, dropboxID: dropboxID)

        let payload = try await manager.serverPayload(now: Date(), uptimeSeconds: 10)

        let rss = try #require(payload.rssMb)
        #expect(abs(rss - 128.5) < 0.001)

        let cpu = try #require(payload.cpuUserMs)
        #expect(abs(cpu - 450.0) < 0.001)

        let rpc = try #require(payload.rpcCount)
        #expect(rpc == 17)

        let conn = try #require(payload.connections)
        #expect(conn == 3)

        let proto = try #require(payload.protoVersion)
        #expect(proto == "2025-11-25")

        let kernel = try #require(payload.kernelBackend)
        #expect(kernel == "simd")
    }

    @Test("serverPayload totalMetrics equals countMetrics — uses COUNT(*) not full scan")
    func serverPayloadTotalMetricsMatchesCount() async throws {
        let manager = try await makeStartedManager()
        defer { Task { await manager.stop() } }

        let store = try await manager.statsStore()
        let dropboxID = "count-test"

        // Insert 4 rows with mixed names — only some are server metric names.
        try await store.insertMetric(name: "server.rss_mb", value: 100.0, tags: [:],
                                     ts: 1.0, dropboxID: dropboxID)
        try await store.insertMetric(name: "some.other.metric", value: 2.0, tags: [:],
                                     ts: 2.0, dropboxID: dropboxID)
        try await store.insertMetric(name: "another.metric", value: 3.0, tags: [:],
                                     ts: 3.0, dropboxID: dropboxID)
        try await store.insertMetric(name: "server.cpu_user_ms", value: 50.0, tags: [:],
                                     ts: 4.0, dropboxID: dropboxID)

        // serverPayload totalMetrics must equal the full row count (countMetrics),
        // not just the count of server-named metrics.
        let count = try await store.countMetrics()
        let payload = try await manager.serverPayload(now: Date(), uptimeSeconds: 0)

        #expect(count == 4, "Store should have 4 metric rows")
        #expect(payload.totalMetrics == count,
                "totalMetrics (\(payload.totalMetrics)) must equal countMetrics (\(count))")
    }
}
