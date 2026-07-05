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
//   7. Tags JSON round-trip: insert metric with multi-key tags dict, read back, assert all tags.
//   8. Empty tags: insert metric with empty tags map, read back, assert empty dict.
//   9. DB-layer health: storageStats() returns non-nil result with logicalSizeBytes > 0.
//   10. queryMetricsByNames: name-IN filter returns only matching rows; empty set is no-op.
//   11. countMetrics: COUNT(*) returns the correct row count without row decoding.
//
// Both-ports parity: the Rust tests in observer_sink/tests/conformance.rs exercise
// the same scenarios with the same table names and flag semantics.
//   12. v3→v4 migration: seed a v3-state DB (no dropbox index), re-open via StatsStore,
//       assert schemaVersion==4 in _storagekit_migrations and idx_metric_samples_dropbox_id exists.

import Testing
import Foundation
import IntellectusLib
import PersistenceKit
import PersistenceKitSQLite
// SQLCipher: migration test seeds a v3 DB via the C API and verifies the
// index after v3→v4 migration. Must be the SAME vendored engine as
// PersistenceKitSQLite (not system SQLite3) — see Package.swift note.
import SQLCipher
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
        // Schema version 5: composite idx_metric_samples_dropbox_name_ts added (v4→v5).
        #expect(StatsStore.schemaVersion == 5)
    }

    @Test("StatsStore seeds monitoring ON by default (wave 8.1)")
    func controlRowsSeededOnOpen() async throws {
        let store = try await makeStore()
        defer { Task { await store.close() } }

        // Wave 8.1: monitoring defaults to ON for new estates.
        let monitoringOn = try await store.isMonitoringEnabled()
        #expect(monitoringOn == true)
    }

    // MARK: 2. Monitoring flag round-trip

    @Test("Monitoring flag write-read round-trip (default ON)")
    func monitoringFlagRoundTrip() async throws {
        let store = try await makeStore()
        defer { Task { await store.close() } }

        // Wave 8.1 default is ON.
        #expect(try await store.isMonitoringEnabled() == true)

        // Disable.
        try await store.setMonitoringEnabled(false)
        #expect(try await store.isMonitoringEnabled() == false)

        // Re-enable.
        try await store.setMonitoringEnabled(true)
        #expect(try await store.isMonitoringEnabled() == true)
    }

    @Test("setMonitoringEnabled writes user source marker — prevents migration reverting it")
    func monitoringUserSourceMarkerPreventsRevert() async throws {
        let url = makeTempURL()

        // Open fresh: monitoring=1, source=default (wave 8.1 seed).
        let store1 = try StatsStore(url: url)
        try await store1.open()
        #expect(try await store1.isMonitoringEnabled() == true)
        // User explicitly turns monitoring off.
        try await store1.setMonitoringEnabled(false)
        #expect(try await store1.isMonitoringEnabled() == false)
        await store1.close()

        // Re-open: the wave 8.1 migration checks source == "user" and must NOT flip back to 1.
        let store2 = try StatsStore(url: url)
        try await store2.open()
        defer { Task { await store2.close() } }
        // Source was "user" → migration skips → monitoring stays off.
        #expect(try await store2.isMonitoringEnabled() == false,
                "User-set monitoring=off must survive a store re-open (wave 8.1 migration must not revert it)")
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

        // Monitoring defaults ON (wave 8.1) — turn it off explicitly to
        // exercise the discard path.
        try await store.setMonitoringEnabled(false)
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

    // MARK: 10. queryMetricsByNames — name-IN filter

    @Test("queryMetricsByNames returns only rows matching the named set")
    func queryMetricsByNamesFiltersCorrectly() async throws {
        let store = try await makeStore()
        defer { Task { await store.close() } }

        let dropboxID = "test-dropbox-bynames"
        try await store.insertMetric(name: "a", value: 1.0, tags: [:], ts: 100.0, dropboxID: dropboxID)
        try await store.insertMetric(name: "b", value: 2.0, tags: [:], ts: 101.0, dropboxID: dropboxID)
        try await store.insertMetric(name: "c", value: 3.0, tags: [:], ts: 102.0, dropboxID: dropboxID)

        let rows = try await store.queryMetricsByNames(["a", "b"])
        #expect(rows.count == 2, "Expected exactly 2 rows (a and b)")
        let names = Set(rows.map(\.name))
        #expect(names == ["a", "b"], "Expected only names 'a' and 'b'")
        #expect(!names.contains("c"), "Row 'c' must not appear in the result")
    }

    @Test("queryMetricsByNames with empty set returns [] without querying")
    func queryMetricsByNamesEmptySetReturnsEmpty() async throws {
        let store = try await makeStore()
        defer { Task { await store.close() } }

        let dropboxID = "test-dropbox-bynames-empty"
        try await store.insertMetric(name: "x", value: 1.0, tags: [:], ts: 100.0, dropboxID: dropboxID)

        let rows = try await store.queryMetricsByNames([])
        #expect(rows.isEmpty, "Empty name set must return [] immediately")
    }

    @Test("queryMetricsByNames with dropboxID further filters by dropbox")
    func queryMetricsByNamesWithDropboxFilter() async throws {
        let store = try await makeStore()
        defer { Task { await store.close() } }

        try await store.insertMetric(name: "m", value: 1.0, tags: [:], ts: 100.0, dropboxID: "box-1")
        try await store.insertMetric(name: "m", value: 2.0, tags: [:], ts: 101.0, dropboxID: "box-2")

        let rows = try await store.queryMetricsByNames(["m"], dropboxID: "box-1")
        #expect(rows.count == 1, "Expected 1 row for box-1 only")
        #expect(rows.first?.dropboxID == "box-1")
    }

    // MARK: 11. countMetrics — COUNT(*) aggregate

    @Test("countMetrics returns correct row count")
    func countMetricsReturnsCorrectCount() async throws {
        let store = try await makeStore()
        defer { Task { await store.close() } }

        // Empty store: count is zero.
        #expect(try await store.countMetrics() == 0, "Empty store must report 0")

        let dropboxID = "test-dropbox-count"
        try await store.insertMetric(name: "m1", value: 1.0, tags: [:], ts: 100.0, dropboxID: dropboxID)
        try await store.insertMetric(name: "m2", value: 2.0, tags: [:], ts: 101.0, dropboxID: dropboxID)
        try await store.insertMetric(name: "m3", value: 3.0, tags: [:], ts: 102.0, dropboxID: dropboxID)

        #expect(try await store.countMetrics() == 3, "Expected count 3 after three inserts")
    }

    // MARK: 12. Topology snapshot — schema version bump

    @Test("StatsStore schema is version 5 after composite index added")
    func schemaVersionIsFive() async throws {
        // v1→v2: topology_snapshots table.
        // v2→v3: topology_snapshots.topology_fingerprint.
        // v3→v4: idx_metric_samples_dropbox_id (per-dropbox COUNT is now O(log n)).
        // v4→v5: composite idx_metric_samples_dropbox_name_ts replaces the v4 index,
        //        enabling per-(dropbox, name) ORDER BY ts DESC LIMIT 1 pure index seeks.
        #expect(StatsStore.schemaVersion == 5)
    }

    // MARK: 13. Topology snapshot write and read

    @Test("writeTopologySnapshot stores payload and latestTopologySnapshot returns it")
    func topologySnapshotRoundTrip() async throws {
        let store = try await makeStore()
        defer { Task { await store.close() } }

        let estate = "estate-topology-001"
        let generatedAt = Date(timeIntervalSince1970: 1_700_000_000.0)
        let payload = Data("""
            {"nodes":[],"edges":[],"communities":[],"structurePending":false,"generatedTs":"2023-11-14T22:13:20.000Z"}
            """.utf8)

        try await store.writeTopologySnapshot(estate: estate, generatedAt: generatedAt, payload: payload)

        let result = try await store.latestTopologySnapshot(estate: estate)
        let roundtripped = try #require(result, "Expected non-nil snapshot after write")
        #expect(roundtripped == payload, "Stored payload must round-trip verbatim")
    }

    // MARK: 13b. Topology fingerprint persist / load round-trip (F5)

    @Test("writeTopologySnapshot persists the fingerprint and loadTopologyFingerprint returns it")
    func topologyFingerprintRoundTrip() async throws {
        let store = try await makeStore()
        defer { Task { await store.close() } }

        let estate = "estate-topology-fp-001"
        let generatedAt = Date(timeIntervalSince1970: 1_700_000_000.0)
        let payload = Data(#"{"nodes":[],"edges":[],"communities":[],"structurePending":false,"generatedTs":"x"}"#.utf8)
        let fingerprint = "3:1:0:0:0:42:7:18446744073709551615"

        // No fingerprint persisted yet → load returns nil.
        let before = try await store.loadTopologyFingerprint(estate: estate)
        #expect(before == nil, "No fingerprint should exist before the first write")

        try await store.writeTopologySnapshot(
            estate: estate, generatedAt: generatedAt, payload: payload, fingerprint: fingerprint)

        let after = try await store.loadTopologyFingerprint(estate: estate)
        #expect(after == fingerprint, "Persisted fingerprint must round-trip verbatim")
    }

    @Test("writeTopologySnapshot without a fingerprint leaves the column null")
    func topologyFingerprintNullWhenOmitted() async throws {
        let store = try await makeStore()
        defer { Task { await store.close() } }

        let estate = "estate-topology-fp-002"
        let generatedAt = Date(timeIntervalSince1970: 1_700_000_000.0)
        let payload = Data(#"{"nodes":[],"structurePending":false}"#.utf8)

        // Omit the fingerprint (legacy 3-arg call path).
        try await store.writeTopologySnapshot(estate: estate, generatedAt: generatedAt, payload: payload)

        let fp = try await store.loadTopologyFingerprint(estate: estate)
        #expect(fp == nil, "Omitted fingerprint must read back as nil (null column)")
    }

    @Test("a later write updates the persisted fingerprint")
    func topologyFingerprintLatestWins() async throws {
        let store = try await makeStore()
        defer { Task { await store.close() } }

        let estate = "estate-topology-fp-003"
        let payload = Data(#"{"structurePending":false}"#.utf8)
        let t1 = Date(timeIntervalSince1970: 1_000_000.0)
        let t2 = Date(timeIntervalSince1970: 2_000_000.0)

        try await store.writeTopologySnapshot(estate: estate, generatedAt: t1, payload: payload, fingerprint: "fp-old")
        try await store.writeTopologySnapshot(estate: estate, generatedAt: t2, payload: payload, fingerprint: "fp-new")

        let fp = try await store.loadTopologyFingerprint(estate: estate)
        #expect(fp == "fp-new", "Latest write must supersede the previous fingerprint")
    }

    // MARK: 14. Topology snapshot latest-wins upsert

    @Test("writeTopologySnapshot overwrites the previous snapshot for the same estate")
    func topologySnapshotLatestWins() async throws {
        let store = try await makeStore()
        defer { Task { await store.close() } }

        let estate = "estate-topology-002"
        let firstPayload = Data("first-payload".utf8)
        let secondPayload = Data("second-payload".utf8)

        let t1 = Date(timeIntervalSince1970: 1_000_000.0)
        let t2 = Date(timeIntervalSince1970: 2_000_000.0)

        try await store.writeTopologySnapshot(estate: estate, generatedAt: t1, payload: firstPayload)
        try await store.writeTopologySnapshot(estate: estate, generatedAt: t2, payload: secondPayload)

        // Latest-wins: only secondPayload survives.
        let result = try await store.latestTopologySnapshot(estate: estate)
        let got = try #require(result)
        #expect(got == secondPayload, "Second write must supersede the first")
    }

    // MARK: 15. Topology snapshot per-estate isolation

    @Test("topology snapshots for different estates are independent")
    func topologySnapshotPerEstateIsolation() async throws {
        let store = try await makeStore()
        defer { Task { await store.close() } }

        let estateA = "estate-topology-A"
        let estateB = "estate-topology-B"
        let payloadA = Data("payload-A".utf8)
        let payloadB = Data("payload-B".utf8)
        let generatedAt = Date(timeIntervalSince1970: 1_000_000.0)

        try await store.writeTopologySnapshot(estate: estateA, generatedAt: generatedAt, payload: payloadA)
        try await store.writeTopologySnapshot(estate: estateB, generatedAt: generatedAt, payload: payloadB)

        let gotA = try await store.latestTopologySnapshot(estate: estateA)
        let gotB = try await store.latestTopologySnapshot(estate: estateB)

        #expect(try #require(gotA) == payloadA, "Estate A payload must be isolated")
        #expect(try #require(gotB) == payloadB, "Estate B payload must be isolated")
    }

    @Test("nil estate returns the newest snapshot across all estates")
    func topologySnapshotNilEstateReturnsNewest() async throws {
        let store = try await makeStore()
        defer { Task { await store.close() } }

        // Two estates, B generated later — the dashboard's default ("all")
        // view reads with nil and must get B's payload.
        try await store.writeTopologySnapshot(
            estate: "estate-older", generatedAt: Date(timeIntervalSince1970: 1_000_000.0),
            payload: Data("payload-older".utf8))
        try await store.writeTopologySnapshot(
            estate: "estate-newer", generatedAt: Date(timeIntervalSince1970: 2_000_000.0),
            payload: Data("payload-newer".utf8))

        let got = try await store.latestTopologySnapshot(estate: nil)
        #expect(try #require(got) == Data("payload-newer".utf8),
                "nil estate must return the newest generated_at across estates")
    }

    @Test("nil estate: newest wins regardless of write order (regression)")
    func topologySnapshotNilEstateNewestWinsRegardlessOfOrder() async throws {
        let store = try await makeStore()
        defer { Task { await store.close() } }

        // Newer written FIRST: the generated_at tie-break bug (read matched only
        // .timestamp, but the column is TEXT ISO-8601, so all rows tied at
        // .distantPast) would wrongly return the older row. The fix compares the
        // ISO-8601 strings, so the newest wins regardless of order.
        try await store.writeTopologySnapshot(
            estate: "estate-newer", generatedAt: Date(timeIntervalSince1970: 2_000_000.0),
            payload: Data("payload-newer".utf8))
        try await store.writeTopologySnapshot(
            estate: "estate-older", generatedAt: Date(timeIntervalSince1970: 1_000_000.0),
            payload: Data("payload-older".utf8))

        let got = try await store.latestTopologySnapshot(estate: nil)
        #expect(try #require(got) == Data("payload-newer".utf8),
                "newest generated_at must win even when the newer row is written first")
    }

    @Test("nil estate returns nil when no snapshots exist")
    func topologySnapshotNilEstateEmptyStore() async throws {
        let store = try await makeStore()
        defer { Task { await store.close() } }
        let got = try await store.latestTopologySnapshot(estate: nil)
        #expect(got == nil)
    }

    // MARK: 16. Topology snapshot missing estate returns nil

    @Test("latestTopologySnapshot returns nil for unknown estate")
    func topologySnapshotMissingReturnsNil() async throws {
        let store = try await makeStore()
        defer { Task { await store.close() } }

        let result = try await store.latestTopologySnapshot(estate: "no-such-estate")
        #expect(result == nil, "Unknown estate must return nil")
    }

    // MARK: 17. queryMetricAggregatesByDropbox — aggregate query correctness

    @Test("queryMetricAggregatesByDropbox returns correct count and lastTs per dropbox")
    func metricAggregatesByDropbox() async throws {
        let store = try await makeStore()
        defer { Task { await store.close() } }

        let idA = "dropbox-A"
        let idB = "dropbox-B"
        let idC = "dropbox-C"   // intentionally no rows

        // Insert 3 rows for A (t=100, 200, 300) and 2 rows for B (t=50, 150).
        // The highest ts values are 300 for A and 150 for B.
        let tsA: [Double] = [100, 200, 300]
        let tsB: [Double] = [50, 150]
        for ts in tsA {
            try await store.insertMetric(name: "m", value: 1.0, tags: [:], ts: ts, dropboxID: idA)
        }
        for ts in tsB {
            try await store.insertMetric(name: "m", value: 1.0, tags: [:], ts: ts, dropboxID: idB)
        }

        let aggregates = try await store.queryMetricAggregatesByDropbox(
            forDropboxIDs: [idA, idB, idC]
        )

        #expect(aggregates.count == 3, "Must return one aggregate per requested dropbox")

        // Dropbox A: 3 rows, lastTs ISO-8601 for epoch 300.
        let a = try #require(aggregates.first(where: { $0.dropboxID == idA }),
                             "Aggregate for dropbox A must be present")
        #expect(a.metricCount == 3, "Dropbox A must have 3 rows; got \(a.metricCount)")
        #expect(a.lastMetricTs != nil, "Dropbox A lastMetricTs must be non-nil")

        // Dropbox B: 2 rows.
        let b = try #require(aggregates.first(where: { $0.dropboxID == idB }),
                             "Aggregate for dropbox B must be present")
        #expect(b.metricCount == 2, "Dropbox B must have 2 rows; got \(b.metricCount)")

        // Dropbox C: 0 rows, lastTs nil.
        let c = try #require(aggregates.first(where: { $0.dropboxID == idC }),
                             "Aggregate for dropbox C must be present even with 0 rows")
        #expect(c.metricCount == 0, "Dropbox C must have 0 rows; got \(c.metricCount)")
        #expect(c.lastMetricTs == nil, "Dropbox C lastMetricTs must be nil when no rows exist")

        // Verify that lastTs for A corresponds to the highest ts (300s epoch).
        // ISO-8601 strings are lexicographically sortable so ts-300 > ts-100.
        if let aTs = a.lastMetricTs, let bTs = b.lastMetricTs {
            // epoch 300 (A) > epoch 150 (B) → A's lastTs must compare greater.
            #expect(aTs > bTs, "lastMetricTs for A (t=300) must be newer than B (t=150); got A=\(aTs), B=\(bTs)")
        }
    }

    @Test("queryMetricAggregatesByDropbox returns empty for empty input")
    func metricAggregatesByDropboxEmptyInput() async throws {
        let store = try await makeStore()
        defer { Task { await store.close() } }

        let result = try await store.queryMetricAggregatesByDropbox(forDropboxIDs: [])
        #expect(result.isEmpty, "Empty input must return empty result")
    }

    // MARK: 18. queryLatestMetricsByNamesAndDropboxes — per-pair latest-row query

    /// 10k rows across 4 (name, dropboxID) pairs — result count must equal 4,
    /// not 10k. This is the core correctness proof for the estatesPayload fix:
    /// the method returns the LATEST row per group, not all rows.
    @Test("queryLatestMetricsByNamesAndDropboxes returns one row per group, not table size")
    func latestMetricsByNamesAndDropboxesGroupCount() async throws {
        let store = try await makeStore()
        defer { Task { await store.close() } }

        // Seed 10k rows across 2 names × 2 dropboxes (2500 rows per pair).
        // Row timestamps are sequential (ts=1, 2, ..., 10000).
        // The most-recent row per (name, dropboxID) is the one with the highest ts.
        let names: [String] = ["metric.a", "metric.b"]
        let dropboxes: [String] = ["dropbox-1", "dropbox-2"]
        var ts = 1.0
        let rowsPerGroup = 2_500
        for name in names {
            for dropbox in dropboxes {
                for _ in 0..<rowsPerGroup {
                    try await store.insertMetric(
                        name: name, value: ts, tags: ["group": "\(name):\(dropbox)"],
                        ts: ts, dropboxID: dropbox
                    )
                    ts += 1
                }
            }
        }

        let result = try await store.queryLatestMetricsByNamesAndDropboxes(
            Set(names), dropboxIDs: dropboxes
        )

        // Must return exactly 4 rows (one per group), not 10k.
        #expect(
            result.count == names.count * dropboxes.count,
            "Must return one row per (name, dropboxID) pair; got \(result.count)"
        )

        // Verify each row is the LATEST (highest ts) for its group.
        // The last row inserted for each (name, dropboxID) has the highest value.
        for name in names {
            for dropbox in dropboxes {
                let row = result.first(where: { $0.name == name && $0.dropboxID == dropbox })
                let r = try #require(row, "Row for (\(name), \(dropbox)) must be present")
                // Each group's last insert has value = ts of that insert (the max for the group).
                // Group rows were inserted in batches so the max ts for (name, dropbox) is
                // not trivially predictable by index — assert the row has the highest ts for
                // that group rather than a specific constant.
                let allForGroup = try await store.queryMetricsByNames(Set([name]), dropboxID: dropbox)
                let maxTs = allForGroup.max(by: { $0.ts < $1.ts })?.ts
                #expect(r.ts == maxTs, "Latest row for (\(name), \(dropbox)) must have max ts; got \(r.ts)")
            }
        }
    }

    @Test("queryLatestMetricsByNamesAndDropboxes returns empty for empty inputs")
    func latestMetricsByNamesAndDropboxesEmptyInputs() async throws {
        let store = try await makeStore()
        defer { Task { await store.close() } }

        let emptyNames = try await store.queryLatestMetricsByNamesAndDropboxes(
            [], dropboxIDs: ["dropbox-1"]
        )
        #expect(emptyNames.isEmpty, "Empty names must yield empty result")

        let emptyDropboxes = try await store.queryLatestMetricsByNamesAndDropboxes(
            ["metric.a"], dropboxIDs: []
        )
        #expect(emptyDropboxes.isEmpty, "Empty dropboxIDs must yield empty result")
    }

    // MARK: 20. v3 / v4 migration tests

    /// Seed a database at v3 (all StatsStore tables present up through
    /// topology_fingerprint, but WITHOUT idx_metric_samples_dropbox_id).
    /// Uses the same vendored SQLCipher engine as PersistenceKitSQLite —
    /// opening an unencrypted DB with SQLCipher is always valid (no-key mode).
    private func seedV3Database(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw StatsStoreTestError.seedFailed("could not open seed DB at \(url.path)")
        }
        defer { sqlite3_close(db) }

        // All DDL statements that represent the v3 state of ObserverSink:
        //   - _storagekit_migrations table + v3 version row
        //   - metric_samples, event_samples, control (v1 tables)
        //   - topology_snapshots with topology_fingerprint column (v2+v3)
        //   - idx_metric_samples_ts, idx_event_samples_ts (v1 indexes)
        //   - NO idx_metric_samples_dropbox_id (added by v3→v4)
        let statements: [String] = [
            """
            CREATE TABLE "_storagekit_migrations" (
              "kit_id" TEXT NOT NULL,
              "version" INTEGER NOT NULL,
              "applied_at" TEXT NOT NULL,
              PRIMARY KEY ("kit_id")
            )
            """,
            "INSERT INTO \"_storagekit_migrations\" (\"kit_id\", \"version\", \"applied_at\") VALUES ('ObserverSink', 3, '2026-01-01T00:00:00Z')",
            """
            CREATE TABLE "metric_samples" (
              "row_id" TEXT NOT NULL,
              "name" TEXT NOT NULL,
              "value" REAL NOT NULL,
              "tags" TEXT NOT NULL,
              "ts" TEXT NOT NULL,
              "dropbox_id" TEXT NOT NULL,
              PRIMARY KEY ("row_id")
            )
            """,
            """
            CREATE TABLE "event_samples" (
              "row_id" TEXT NOT NULL,
              "kind" TEXT NOT NULL,
              "noun_type" INTEGER NOT NULL,
              "estate_row_id" TEXT NOT NULL,
              "estate" TEXT NOT NULL,
              "ts" TEXT NOT NULL,
              "dropbox_id" TEXT NOT NULL,
              PRIMARY KEY ("row_id")
            )
            """,
            """
            CREATE TABLE "control" (
              "key" TEXT NOT NULL,
              "value" TEXT NOT NULL,
              PRIMARY KEY ("key")
            )
            """,
            // topology_snapshots was added in v2; topology_fingerprint column in v3.
            """
            CREATE TABLE "topology_snapshots" (
              "estate" TEXT NOT NULL,
              "generated_at" TEXT NOT NULL,
              "payload" TEXT NOT NULL,
              "topology_fingerprint" TEXT,
              PRIMARY KEY ("estate")
            )
            """,
            // v1 indexes only — dropbox_id index is deliberately absent.
            "CREATE INDEX \"idx_metric_samples_ts\" ON \"metric_samples\" (\"ts\")",
            "CREATE INDEX \"idx_event_samples_ts\" ON \"event_samples\" (\"ts\")",
        ]

        for sql in statements {
            var errmsg: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(db, sql, nil, nil, &errmsg)
            if rc != SQLITE_OK {
                let msg = errmsg.map { String(cString: $0) } ?? "rc=\(rc)"
                sqlite3_free(errmsg)
                throw StatsStoreTestError.seedFailed("DDL failed: \(msg) — \(sql.prefix(60))")
            }
        }
    }

    /// Seed a database at v4 (all v3 tables plus idx_metric_samples_dropbox_id,
    /// version row = 4). Used by v4→v5 migration test.
    private func seedV4Database(at url: URL) throws {
        // Start from v3 state.
        try seedV3Database(at: url)

        // Advance to v4: update version + add the single-column dropbox_id index.
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw StatsStoreTestError.seedFailed("could not open v4 seed DB at \(url.path)")
        }
        defer { sqlite3_close(db) }

        let statements: [String] = [
            "UPDATE \"_storagekit_migrations\" SET version = 4, applied_at = '2026-01-02T00:00:00Z' WHERE kit_id = 'ObserverSink'",
            "CREATE INDEX \"idx_metric_samples_dropbox_id\" ON \"metric_samples\" (\"dropbox_id\")",
        ]
        for sql in statements {
            var errmsg: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(db, sql, nil, nil, &errmsg)
            if rc != SQLITE_OK {
                let msg = errmsg.map { String(cString: $0) } ?? "rc=\(rc)"
                sqlite3_free(errmsg)
                throw StatsStoreTestError.seedFailed("v4 seed DDL failed: \(msg) — \(sql.prefix(60))")
            }
        }
    }

    /// Verify that opening an existing v3 database through StatsStore applies
    /// the full migration chain (v3→v4→v5): the stored version advances to 5,
    /// the old single-column index is replaced by the composite index.
    @Test("v3 db migrates to v5 through full chain — composite index present, old index absent")
    func v3DatabaseMigratesToV5() async throws {
        let url = makeTempURL()

        // Build the v3 seed DB.
        try seedV3Database(at: url)

        // Open via StatsStore — the migration runner applies v3→v4 then v4→v5.
        let store = try StatsStore(url: url)
        try await store.open()
        await store.close()

        // Re-open with raw SQLCipher to inspect the final DB state.
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            Issue.record("could not re-open seed DB at \(url.path) for verification")
            return
        }
        defer { sqlite3_close(db) }

        // 1. Version must be 5.
        var storedVersion: Int32 = 0
        let verSQL = "SELECT version FROM \"_storagekit_migrations\" WHERE kit_id = 'ObserverSink'"
        var vStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, verSQL, -1, &vStmt, nil) == SQLITE_OK,
           sqlite3_step(vStmt) == SQLITE_ROW {
            storedVersion = sqlite3_column_int(vStmt, 0)
        }
        sqlite3_finalize(vStmt)
        #expect(storedVersion == 5, "v3 db migrated through chain must reach version 5; got \(storedVersion)")

        // 2. Composite index must be present.
        var compositeFound = false
        let compSQL = "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_metric_samples_dropbox_name_ts'"
        var cStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, compSQL, -1, &cStmt, nil) == SQLITE_OK,
           sqlite3_step(cStmt) == SQLITE_ROW {
            compositeFound = true
        }
        sqlite3_finalize(cStmt)
        #expect(compositeFound, "composite index idx_metric_samples_dropbox_name_ts must exist after v3→v5 chain")

        // 3. Old single-column index must be gone (dropped by v4→v5 migration).
        var oldIndexGone = true
        let oldSQL = "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_metric_samples_dropbox_id'"
        var oStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, oldSQL, -1, &oStmt, nil) == SQLITE_OK,
           sqlite3_step(oStmt) == SQLITE_ROW {
            oldIndexGone = false
        }
        sqlite3_finalize(oStmt)
        #expect(oldIndexGone, "old index idx_metric_samples_dropbox_id must be dropped by v4→v5 migration")
    }

    /// Verify that opening an existing v4 database through StatsStore applies
    /// the v4→v5 migration: advances the stored version to 5, drops the
    /// single-column index, and creates the composite index.
    @Test("v4→v5 migration drops old index and adds composite index")
    func v4ToV5MigrationAddsCompositeIndex() async throws {
        let url = makeTempURL()

        // Build the v4 seed DB (v3 base + single-column dropbox_id index, version=4).
        try seedV4Database(at: url)

        // Open via StatsStore — the migration runner detects version=4 < 5
        // and applies the v4→v5 step (DROP INDEX + CREATE INDEX + version upsert).
        let store = try StatsStore(url: url)
        try await store.open()
        await store.close()

        // Re-open with raw SQLCipher to inspect the migrated DB state.
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            Issue.record("could not re-open v4 seed DB at \(url.path) for verification")
            return
        }
        defer { sqlite3_close(db) }

        // 1. Version must now be 5.
        var storedVersion: Int32 = 0
        let verSQL = "SELECT version FROM \"_storagekit_migrations\" WHERE kit_id = 'ObserverSink'"
        var vStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, verSQL, -1, &vStmt, nil) == SQLITE_OK,
           sqlite3_step(vStmt) == SQLITE_ROW {
            storedVersion = sqlite3_column_int(vStmt, 0)
        }
        sqlite3_finalize(vStmt)
        #expect(storedVersion == 5, "v4→v5 migration must record version 5 in _storagekit_migrations; got \(storedVersion)")

        // 2. Composite index must be present after migration.
        var compositeFound = false
        let compSQL = "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_metric_samples_dropbox_name_ts'"
        var cStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, compSQL, -1, &cStmt, nil) == SQLITE_OK,
           sqlite3_step(cStmt) == SQLITE_ROW {
            compositeFound = true
        }
        sqlite3_finalize(cStmt)
        #expect(compositeFound, "v4→v5 migration must create idx_metric_samples_dropbox_name_ts")

        // 3. Old single-column index must be absent after migration.
        var oldIndexGone = true
        let oldSQL = "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_metric_samples_dropbox_id'"
        var oStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, oldSQL, -1, &oStmt, nil) == SQLITE_OK,
           sqlite3_step(oStmt) == SQLITE_ROW {
            oldIndexGone = false
        }
        sqlite3_finalize(oStmt)
        #expect(oldIndexGone, "v4→v5 migration must drop idx_metric_samples_dropbox_id")
    }
}

// Error type scoped to this test file to avoid clashing with production errors.
private enum StatsStoreTestError: Error {
    case seedFailed(String)
}
