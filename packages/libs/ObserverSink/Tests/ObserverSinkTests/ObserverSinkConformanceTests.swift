// ObserverSinkConformanceTests.swift
//
// Both-ports conformance test for the ObserverSink module.
//
// Proves the emit → IntellectusLib → PersistenceKit store → readback pipeline
// and exercises the retention roll-off path.
//
// Test plan:
//   1. Schema / open: open a fresh store, assert schema version is correct.
//   2. Monitoring flag: default is off; set to on; read back on; set to off; read back off.
//   3. Metric emit path: install sink, enable Intellectus, emit .metric, read back row,
//      assert name/value/tags/dropboxID match.
//   4. Event emit path: emit .event, read back row, assert kind/nounType/rowID/estate match.
//   5. Monitoring off: disable store flag, emit more samples, assert no new rows inserted.
//   6. Retention roll-off: insert old + new rows, apply cutoff, assert old rows gone and
//      new rows kept. Tests both deleteMetricsBefore and deleteEventsBefore.
//
// Both-ports parity: the Rust tests in observer_sink/tests/conformance.rs exercise
// the same six scenarios with the same table names and flag semantics.

import Testing
import Foundation
import IntellectusLib
import PersistenceKit
import PersistenceKitSQLite
@testable import ObserverSink

// MARK: - Test helpers

/// Create a fresh temporary SQLite URL for each test.
private func makeTempURL() -> URL {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("observer-sink-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    return tmp.appendingPathComponent("stats.sqlite")
}

/// Open a fresh StatsStore at a temporary URL.
private func makeStore() async throws -> StatsStore {
    let store = try StatsStore(url: makeTempURL())
    try await store.open()
    return store
}

// MARK: - Suite

struct ObserverSinkConformanceTests {

    // MARK: 1. Schema / open

    @Test("StatsStore opens and reports correct schema version")
    func schemaVersion() async throws {
        let store = try await makeStore()
        defer { Task { await store.close() } }
        // The schema version is a constant — verify the store returns it.
        #expect(StatsStore.schemaVersion == 1)
    }

    @Test("StatsStore seeds control rows on open")
    func controlRowsSeededOnOpen() async throws {
        let store = try await makeStore()
        defer { Task { await store.close() } }

        // "monitoring" defaults to off.
        let monitoringOn = try await store.isMonitoringEnabled()
        #expect(monitoringOn == false)
    }

    // MARK: 2. Monitoring flag round-trip

    @Test("Monitoring flag write-read round-trip")
    func monitoringFlagRoundTrip() async throws {
        let store = try await makeStore()
        defer { Task { await store.close() } }

        // Default is off.
        #expect(try await store.isMonitoringEnabled() == false)

        // Enable.
        try await store.setMonitoringEnabled(true)
        #expect(try await store.isMonitoringEnabled() == true)

        // Disable.
        try await store.setMonitoringEnabled(false)
        #expect(try await store.isMonitoringEnabled() == false)
    }

    // MARK: 3. Metric emit path

    @Test("Emit .metric → stored → readback matches")
    func metricEmitReadback() async throws {
        let store = try await makeStore()
        defer { Task { await store.close() } }
        try await store.setMonitoringEnabled(true)

        let dropboxID = "test-dropbox-metric"
        let sink = PersistenceStatsSink(store: store, dropboxID: dropboxID)
        Intellectus.install(sink: sink)
        Intellectus.setEnabled(true)
        defer { Intellectus.setEnabled(false) }

        let ts: Double = 1_700_000_000.0
        let tags: [String: String] = ["kit": "TestKit", "op": "capture"]
        Intellectus.report(.metric(
            name: "locus.capture.latency_ms",
            value: 42.0,
            tags: tags,
            ts: ts
        ))

        // Allow the async Task in PersistenceStatsSink to complete.
        // The task dispatches async I/O; we yield briefly before querying.
        try await Task.sleep(nanoseconds: 100_000_000)   // 100 ms

        let rows = try await store.queryMetrics(dropboxID: dropboxID)
        #expect(rows.count == 1, "Expected exactly one metric row")

        let row = try #require(rows.first)
        #expect(row.name == "locus.capture.latency_ms")
        #expect(row.value == 42.0)
        #expect(row.tags["kit"] == "TestKit")
        #expect(row.tags["op"] == "capture")
        #expect(row.dropboxID == dropboxID)
        // ts stored as ISO-8601 TEXT and read back as Date; check epoch matches within 1 s
        // (millisecond-precision encoding may introduce sub-millisecond rounding).
        #expect(abs(row.ts.timeIntervalSince1970 - ts) < 1.0)
    }

    // MARK: 4. Event emit path

    @Test("Emit .event → stored → readback matches")
    func eventEmitReadback() async throws {
        let store = try await makeStore()
        defer { Task { await store.close() } }
        try await store.setMonitoringEnabled(true)

        let dropboxID = "test-dropbox-event"
        let sink = PersistenceStatsSink(store: store, dropboxID: dropboxID)
        Intellectus.install(sink: sink)
        Intellectus.setEnabled(true)
        defer { Intellectus.setEnabled(false) }

        let ts: Double = 1_700_000_001.0
        let rowUUID = UUID().uuidString
        let estateID = "estate-abc-123"
        Intellectus.report(.event(
            kind: .think,
            nounType: 7,
            rowID: rowUUID,
            estate: estateID,
            ts: ts
        ))

        try await Task.sleep(nanoseconds: 100_000_000)   // 100 ms

        let rows = try await store.queryEvents(dropboxID: dropboxID)
        #expect(rows.count == 1, "Expected exactly one event row")

        let row = try #require(rows.first)
        #expect(row.kind == "think")
        #expect(row.nounType == 7)
        #expect(row.rowIDStr == rowUUID)
        #expect(row.estate == estateID)
        #expect(row.dropboxID == dropboxID)
        #expect(abs(row.ts.timeIntervalSince1970 - ts) < 1.0)
    }

    // MARK: 5. Monitoring off — no writes

    @Test("Sink discards samples when store monitoring flag is off")
    func sinkDiscardsWhenMonitoringOff() async throws {
        let store = try await makeStore()
        defer { Task { await store.close() } }

        // Monitoring stays off (default).
        let dropboxID = "test-dropbox-off"
        let sink = PersistenceStatsSink(store: store, dropboxID: dropboxID)
        Intellectus.install(sink: sink)
        Intellectus.setEnabled(true)
        defer { Intellectus.setEnabled(false) }

        Intellectus.report(.metric(
            name: "should.not.land",
            value: 99.0,
            tags: [:],
            ts: 1_000_000.0
        ))

        try await Task.sleep(nanoseconds: 100_000_000)   // 100 ms

        let rows = try await store.queryMetrics(dropboxID: dropboxID)
        #expect(rows.isEmpty, "Expected no rows when monitoring is off")
    }

    // MARK: 6. Retention roll-off

    @Test("deleteMetricsBefore rolls off old rows, keeps new rows")
    func retentionMetrics() async throws {
        let store = try await makeStore()
        defer { Task { await store.close() } }

        // Insert directly (bypassing the sink) to control ts precisely.
        let dropboxID = "test-dropbox-retention"

        // "old" rows: ts before cutoff (epoch 1000)
        let cutoff = Date(timeIntervalSince1970: 1000.0)
        let nowForTest = Date(timeIntervalSince1970: 2000.0)   // deterministic "now"

        // Two old rows.
        try await store.insertMetric(name: "old.metric", value: 1.0, tags: [:], ts: 500.0,
                                      dropboxID: dropboxID)
        try await store.insertMetric(name: "old.metric", value: 2.0, tags: [:], ts: 999.0,
                                      dropboxID: dropboxID)

        // Two new rows (ts ≥ cutoff).
        try await store.insertMetric(name: "new.metric", value: 3.0, tags: [:], ts: 1000.0,
                                      dropboxID: dropboxID)
        try await store.insertMetric(name: "new.metric", value: 4.0, tags: [:], ts: 1500.0,
                                      dropboxID: dropboxID)

        let beforeCount = try await store.queryMetrics(dropboxID: dropboxID).count
        #expect(beforeCount == 4)

        // Apply retention: delete rows with ts < cutoff (strictly less than).
        let deleted = try await store.deleteMetricsBefore(cutoff: cutoff, now: nowForTest)
        #expect(deleted == 2, "Expected 2 old rows deleted")

        let afterRows = try await store.queryMetrics(dropboxID: dropboxID)
        #expect(afterRows.count == 2, "Expected 2 new rows kept")

        // Verify the surviving rows are the "new" ones (ts ≥ 1000).
        for row in afterRows {
            #expect(row.ts.timeIntervalSince1970 >= 1000.0 - 1.0,
                    "Survived row ts should be at or after cutoff (within 1 s rounding)")
            #expect(row.name == "new.metric")
        }
    }

    @Test("deleteEventsBefore rolls off old event rows, keeps new rows")
    func retentionEvents() async throws {
        let store = try await makeStore()
        defer { Task { await store.close() } }

        let dropboxID = "test-dropbox-retention-events"
        let cutoff = Date(timeIntervalSince1970: 1000.0)
        let nowForTest = Date(timeIntervalSince1970: 2000.0)

        // Two old event rows.
        try await store.insertEvent(kind: "capture", nounType: 1, rowID: UUID().uuidString,
                                     estate: "e1", ts: 500.0, dropboxID: dropboxID)
        try await store.insertEvent(kind: "think", nounType: 2, rowID: UUID().uuidString,
                                    estate: "e1", ts: 999.0, dropboxID: dropboxID)

        // Two new event rows (ts ≥ cutoff).
        try await store.insertEvent(kind: "capture", nounType: 3, rowID: UUID().uuidString,
                                     estate: "e1", ts: 1000.0, dropboxID: dropboxID)
        try await store.insertEvent(kind: "think", nounType: 4, rowID: UUID().uuidString,
                                    estate: "e1", ts: 1500.0, dropboxID: dropboxID)

        let deleted = try await store.deleteEventsBefore(cutoff: cutoff, now: nowForTest)
        #expect(deleted == 2)

        let afterRows = try await store.queryEvents(dropboxID: dropboxID)
        #expect(afterRows.count == 2)

        for row in afterRows {
            #expect(row.ts.timeIntervalSince1970 >= 1000.0 - 1.0)
        }
    }

    // MARK: 7. Tags JSON round-trip

    @Test("Tag map encodes and decodes correctly through the store")
    func tagsJSONRoundTrip() async throws {
        let store = try await makeStore()
        defer { Task { await store.close() } }

        let dropboxID = "test-dropbox-tags"
        let tags = ["alpha": "one", "beta": "two", "gamma": "three"]
        try await store.insertMetric(name: "tags.test", value: 0.0, tags: tags,
                                      ts: 1_000_000.0, dropboxID: dropboxID)

        let rows = try await store.queryMetrics(dropboxID: dropboxID)
        let row = try #require(rows.first)
        #expect(row.tags["alpha"] == "one")
        #expect(row.tags["beta"] == "two")
        #expect(row.tags["gamma"] == "three")
        #expect(row.tags.count == 3)
    }

    // MARK: 2b. Monitoring flag survives re-open (persistent switch)

    @Test("Monitoring flag set to ON survives closing and re-opening the store")
    func monitoringFlagSurvivesReopen() async throws {
        // The manager's on/off switch must persist across process restarts.
        // open() seeds defaults only when absent, so a re-open must NOT reset
        // an operator-set "1" back to "0".
        let url = makeTempURL()

        let first = try StatsStore(url: url)
        try await first.open()
        try await first.setMonitoringEnabled(true)
        await first.close()

        let second = try StatsStore(url: url)
        try await second.open()
        defer { Task { await second.close() } }
        #expect(try await second.isMonitoringEnabled() == true,
                "monitoring flag must survive re-open")
    }

    // MARK: 9. DB-layer health (StorageIntrospection)

    @Test("storageStats reports the SQLite-backed store's own DB-layer health")
    func storageStatsReportsBackendHealth() async throws {
        let store = try await makeStore()
        defer { Task { await store.close() } }

        // Write a row so the store has some content (non-zero size).
        try await store.insertMetric(name: "health.probe", value: 1.0, tags: [:],
                                     ts: 1_000_000.0, dropboxID: "test-dropbox-health")

        // The SQLite backend conforms to StorageIntrospection, so this is non-nil.
        let nowForTest = Date(timeIntervalSince1970: 2_000_000.0)
        let stats = try #require(try await store.storageStats(now: nowForTest))

        // SQLite supplies size and page fields.
        #expect(stats.logicalSizeBytes > 0)
        #expect(stats.pageSize != nil)
        #expect(stats.pageCount != nil)
        // capturedAt is the caller-supplied deterministic clock.
        #expect(stats.capturedAt == nowForTest)
    }

    // MARK: 8. Empty tags

    @Test("Empty tag map is stored and decoded as empty dictionary")
    func emptyTagsRoundTrip() async throws {
        let store = try await makeStore()
        defer { Task { await store.close() } }

        let dropboxID = "test-dropbox-emptytags"
        try await store.insertMetric(name: "no.tags", value: 5.0, tags: [:],
                                      ts: 1_000_000.0, dropboxID: dropboxID)

        let rows = try await store.queryMetrics(dropboxID: dropboxID)
        let row = try #require(rows.first)
        #expect(row.tags.isEmpty)
    }
}
