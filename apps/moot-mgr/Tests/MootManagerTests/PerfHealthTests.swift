// PerfHealthTests.swift
//
// Verify: GET /api/perf-health returns a valid PerfHealthPayload for the
// empty-store case (pending:false, latestSample:nil, trend:[]) and the
// seeded case (latestSample reflects the inserted row, trend has one point).
//
// Mirrors the test idiom from ReviewPaneTests.swift (HTTP loopback path) and
// ServerPayloadMetricsTests.swift (direct MootManager path for sync seeding).

import Testing
import Foundation
import ObserverSink
@testable import MootManager

// MARK: - PerfHealthTests (HTTP endpoint)

private func makeTempStoreURL(tag: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("moot-mgr-perf-health-\(tag)-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("stats.sqlite", isDirectory: false)
}

private func makeTempSocketPath(tag: String) -> String {
    "/tmp/mm-ph-\(tag)-\(UUID().uuidString.prefix(8)).sock"
}

private let phToken = "b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5"

/// Spin up a ResidentHost with an optional store-seed callback, return (host, port).
private func makeStartedHost(
    tag: String = "default",
    seed: (StatsStore) async throws -> Void = { _ in }
) async throws -> (host: ResidentHost, port: UInt16) {
    let cfg = ResidentHostConfig(
        manager: ManagerConfig(storeURL: makeTempStoreURL(tag: tag), retentionWindow: 1_000),
        httpPort: 0,
        controlToken: phToken,
        controlSocketPath: makeTempSocketPath(tag: tag),
        estatesDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("mm-ph-est-\(UUID().uuidString)", isDirectory: true)
    )
    let host = ResidentHost(config: cfg, startInstant: Date(timeIntervalSince1970: 1_000),
                            clock: { Date(timeIntervalSince1970: 2_000) })
    try await host.start()
    let store = try await host.managerHandle().statsStore()
    try await seed(store)
    let port = await host.boundHTTPPort()
    return (host, port)
}

private func httpGET(port: UInt16, path: String) async throws
    -> (status: Int, body: String)
{
    let r = try await loopbackHTTP(port: port, path: path)
    return (r.status, r.body)
}

// MARK: - HTTP endpoint tests

@Suite struct PerfHealthEndpointTests {

    @Test("GET /api/perf-health returns 200")
    func perfHealthEndpointReturns200() async throws {
        let (host, port) = try await makeStartedHost(tag: "200")
        defer { Task { await host.stop() } }

        let (status, _) = try await httpGET(port: port, path: "/api/perf-health")
        #expect(status == 200)
    }

    @Test("GET /api/perf-health on empty store returns valid shape")
    func perfHealthEmptyStoreShape() async throws {
        let (host, port) = try await makeStartedHost(tag: "shape")
        defer { Task { await host.stop() } }

        let (status, body) = try await httpGET(port: port, path: "/api/perf-health")
        #expect(status == 200)

        let data = Data(body.utf8)
        let obj = try #require(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Required top-level fields must be present.
        #expect(obj["pending"] != nil, "missing pending field")
        #expect(obj["trend"] != nil, "missing trend field")
    }

    @Test("GET /api/perf-health empty store → pending:false, latestSample:null, trend:[]")
    func perfHealthEmptyStoreCounts() async throws {
        let (host, port) = try await makeStartedHost(tag: "counts")
        defer { Task { await host.stop() } }

        let (_, body) = try await httpGET(port: port, path: "/api/perf-health")
        let data = Data(body.utf8)
        let obj = try #require(try? JSONSerialization.jsonObject(with: data) as? [String: Any])

        let pending = try #require(obj["pending"] as? Bool)
        #expect(pending == false, "empty store should not be pending")

        let trend = try #require(obj["trend"] as? [Any])
        #expect(trend.isEmpty, "trend should be empty when no samples exist")

        // latestSample should be absent (JSON null / missing key) on an empty store.
        // JSONSerialization maps JSON null to NSNull.
        let sampleVal = obj["latestSample"]
        let isNullOrAbsent = sampleVal == nil || sampleVal is NSNull
        #expect(isNullOrAbsent, "latestSample should be null when no samples exist")
    }

    @Test("GET /api/perf-health reflects seeded ingest_p50_ms in latestSample and trend")
    func perfHealthReflectsSeededMetric() async throws {
        let estateUUID = UUID().uuidString
        let dropboxID = "perf-health-test"
        let sampleTs = 100_000.0   // epoch seconds

        let (host, port) = try await makeStartedHost(tag: "seed") { store in
            // Insert one ingest_p50_ms sample tagged with the estate UUID.
            // Using insertMetric directly for synchronous seeding (avoids
            // PersistenceStatsSink's unstructured Task race — see ServerPayloadMetricsTests).
            try await store.insertMetric(
                name: "neuronkit.perf_health.ingest_p50_ms",
                value: 42.5,
                tags: ["estate": estateUUID],
                ts: sampleTs,
                dropboxID: dropboxID
            )
            try await store.insertMetric(
                name: "neuronkit.perf_health.ingest_p95_ms",
                value: 88.0,
                tags: ["estate": estateUUID],
                ts: sampleTs,
                dropboxID: dropboxID
            )
            try await store.insertMetric(
                name: "neuronkit.perf_health.ingest_sample_count",
                value: 17.0,
                tags: ["estate": estateUUID],
                ts: sampleTs,
                dropboxID: dropboxID
            )
        }
        defer { Task { await host.stop() } }

        let (status, body) = try await httpGET(port: port, path: "/api/perf-health")
        #expect(status == 200)

        let data = Data(body.utf8)
        let obj = try #require(try? JSONSerialization.jsonObject(with: data) as? [String: Any])

        // latestSample must be present and contain ingestP50Ms.
        let sample = try #require(obj["latestSample"] as? [String: Any],
                                   "latestSample must be present when samples exist")
        let ingestP50 = try #require(sample["ingestP50Ms"] as? Double)
        #expect(abs(ingestP50 - 42.5) < 0.01, "ingestP50Ms should reflect seeded value")

        // trend must have one point with matching value.
        let trend = try #require(obj["trend"] as? [[String: Any]])
        #expect(trend.count == 1, "trend should have one point for one seeded row")
        let point = try #require(trend.first)
        let trendP50 = try #require(point["ingestP50Ms"] as? Double)
        #expect(abs(trendP50 - 42.5) < 0.01, "trend point should match seeded ingest_p50_ms")
    }
}

// MARK: - Direct builder tests (MootManager without HTTP stack)

@Suite("PerfHealthPayload builder", .serialized)
struct PerfHealthPayloadTests {

    private func makeStartedManager() async throws -> MootManager {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ph-builder-\(UUID().uuidString)", isDirectory: true)
        let url = tmp.appendingPathComponent("stats.sqlite", isDirectory: false)
        let manager = MootManager(config: ManagerConfig(storeURL: url, retentionWindow: 3_600))
        try await manager.start()
        return manager
    }

    @Test("perfHealthPayload returns nil latestSample when store has no perf-health rows")
    func nilWhenNoSamples() async throws {
        let manager = try await makeStartedManager()
        defer { Task { await manager.stop() } }

        let payload = try await manager.perfHealthPayload()
        #expect(payload.pending == false)
        #expect(payload.latestSample == nil)
        #expect(payload.trend.isEmpty)
    }

    @Test("perfHealthPayload populates latestSample from seeded rows")
    func populatedFromStore() async throws {
        let manager = try await makeStartedManager()
        defer { Task { await manager.stop() } }

        let store = try await manager.statsStore()
        let estateID = UUID().uuidString
        let ts = 200_000.0

        try await store.insertMetric(
            name: "neuronkit.perf_health.ingest_p50_ms",
            value: 55.0,
            tags: ["estate": estateID],
            ts: ts,
            dropboxID: "builder-test"
        )
        try await store.insertMetric(
            name: "neuronkit.perf_health.cycle_vector_p50_ms",
            value: 120.0,
            tags: ["estate": estateID],
            ts: ts,
            dropboxID: "builder-test"
        )

        let payload = try await manager.perfHealthPayload()
        let sample = try #require(payload.latestSample)
        let p50 = try #require(sample.ingestP50Ms)
        #expect(abs(p50 - 55.0) < 0.01, "ingestP50Ms should reflect seeded value")
        let vecP50 = try #require(sample.cycleVectorP50Ms)
        #expect(abs(vecP50 - 120.0) < 0.01, "cycleVectorP50Ms should reflect seeded value")
    }

    @Test("perfHealthPayload estate filter narrows latestSample and trend")
    func estateFilterNarrows() async throws {
        let manager = try await makeStartedManager()
        defer { Task { await manager.stop() } }

        let store = try await manager.statsStore()
        let estateA = UUID().uuidString
        let estateB = UUID().uuidString
        let ts = 300_000.0

        // Seed two estates with different p50 values.
        try await store.insertMetric(
            name: "neuronkit.perf_health.ingest_p50_ms",
            value: 10.0,
            tags: ["estate": estateA],
            ts: ts,
            dropboxID: "filter-test"
        )
        try await store.insertMetric(
            name: "neuronkit.perf_health.ingest_p50_ms",
            value: 99.0,
            tags: ["estate": estateB],
            ts: ts + 1,
            dropboxID: "filter-test"
        )

        // Unfiltered: trend has two points (one per estate).
        let allPayload = try await manager.perfHealthPayload()
        #expect(allPayload.trend.count == 2,
                "unfiltered trend should contain one point per seeded estate")

        // Filtered to estateA: trend has one point with value 10.
        let aPayload = try await manager.perfHealthPayload(estate: estateA)
        #expect(aPayload.trend.count == 1, "estate-filtered trend should have one point")
        let aP50 = try #require(aPayload.trend.first?.ingestP50Ms)
        #expect(abs(aP50 - 10.0) < 0.01, "estate-A trend value should be 10.0")

        // Filtered to estateB: trend has one point with value 99.
        let bPayload = try await manager.perfHealthPayload(estate: estateB)
        #expect(bPayload.trend.count == 1)
        let bP50 = try #require(bPayload.trend.first?.ingestP50Ms)
        #expect(abs(bP50 - 99.0) < 0.01, "estate-B trend value should be 99.0")
    }

    @Test("perfHealthPayload caps the trend at the newest 366 points (PH-01)")
    func trendCappedAtNewest366() async throws {
        let manager = try await makeStartedManager()
        defer { Task { await manager.stop() } }

        let store = try await manager.statsStore()
        let estateID = UUID().uuidString

        // Seed MORE ingest_p50 rows than the trend cap (366). Sequential ts:
        // row i is older than row i+1.
        let total = 400
        for i in 0..<total {
            try await store.insertMetric(
                name: "neuronkit.perf_health.ingest_p50_ms",
                value: Double(i),
                tags: ["estate": estateID],
                ts: 100_000.0 + Double(i),
                dropboxID: "cap-test"
            )
        }

        let payload = try await manager.perfHealthPayload(estate: estateID)

        // 366 = perfHealthMaxTrendPoints (one year of daily duty runs).
        // Deliberately hardcoded: the bound is contractual — if the constant
        // drifts, this test must fail and force a deliberate decision.
        #expect(payload.trend.count == 366,
                "trend must be capped at 366 points; got \(payload.trend.count)")
        // The cap keeps the NEWEST points and drops the oldest: the last
        // point is the newest seeded row, the first is (total - 366).
        let first = try #require(payload.trend.first)
        let last = try #require(payload.trend.last)
        #expect(abs(last.ingestP50Ms - Double(total - 1)) < 0.01,
                "last trend point must be the newest sample")
        #expect(abs(first.ingestP50Ms - Double(total - 366)) < 0.01,
                "first trend point must be the oldest RETAINED sample (newest 366 kept)")
        // Oldest-first ordering must survive the bounded DESC fetch + re-sort.
        #expect(first.ts < last.ts, "trend must remain oldest-first")

        // latestSample still reflects the newest row despite the bound.
        let sample = try #require(payload.latestSample)
        let p50 = try #require(sample.ingestP50Ms)
        #expect(abs(p50 - Double(total - 1)) < 0.01,
                "latestSample must be the newest row, not a truncated older one")
    }

    @Test("perfHealthPayload below the caps is unchanged by the bounds (PH-01)")
    func normalVolumeUnchangedByBounds() async throws {
        let manager = try await makeStartedManager()
        defer { Task { await manager.stop() } }

        let store = try await manager.statsStore()
        let estateID = UUID().uuidString

        // A realistic volume (three daily duty runs) — far below both the
        // row-query cap (8192) and the trend cap (366).
        for i in 0..<3 {
            try await store.insertMetric(
                name: "neuronkit.perf_health.ingest_p50_ms",
                value: Double(10 + i),
                tags: ["estate": estateID],
                ts: 500_000.0 + Double(i) * 86_400.0,
                dropboxID: "normal-test"
            )
        }

        let payload = try await manager.perfHealthPayload(estate: estateID)
        #expect(payload.trend.count == 3, "all points must survive below the cap")
        let values = payload.trend.map(\.ingestP50Ms)
        #expect(values == [10.0, 11.0, 12.0],
                "trend must be complete and oldest-first, exactly as seeded")
        let sample = try #require(payload.latestSample)
        let p50 = try #require(sample.ingestP50Ms)
        #expect(abs(p50 - 12.0) < 0.01)
    }

    @Test("perfHealthPayload trend is ordered oldest first")
    func trendOldestFirst() async throws {
        let manager = try await makeStartedManager()
        defer { Task { await manager.stop() } }

        let store = try await manager.statsStore()
        let estateID = UUID().uuidString

        // Insert two rows at different timestamps; earlier ts = older.
        try await store.insertMetric(
            name: "neuronkit.perf_health.ingest_p50_ms",
            value: 1.0,
            tags: ["estate": estateID],
            ts: 100_000.0,
            dropboxID: "order-test"
        )
        try await store.insertMetric(
            name: "neuronkit.perf_health.ingest_p50_ms",
            value: 2.0,
            tags: ["estate": estateID],
            ts: 200_000.0,
            dropboxID: "order-test"
        )

        let payload = try await manager.perfHealthPayload(estate: estateID)
        #expect(payload.trend.count == 2)
        // Oldest first means the row with value 1.0 should come before value 2.0.
        let first = try #require(payload.trend.first)
        let last  = try #require(payload.trend.last)
        #expect(abs(first.ingestP50Ms - 1.0) < 0.01, "first trend point should be the older sample")
        #expect(abs(last.ingestP50Ms  - 2.0) < 0.01, "last trend point should be the newer sample")
    }
}
