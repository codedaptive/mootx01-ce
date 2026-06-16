// MootManagerTests.swift
//
// Phase-1 verify line (MANAGER_1.0_PLAN.md §3): the whole pipeline proven on
// real data through the manager and a real ObserverSink consumer.
//
// End-to-end integration test (the authoritative Phase-1 proof):
//   manager sets monitoring ON → consumer report(...)s a metric + event →
//   rows land in the store → retention with a cutoff rolls off old rows but
//   keeps new → manager sets monitoring OFF → consumer emission stops.
//
// Plus focused tests for config resolution, the CLI parser, the status
// surface grouping, and the manager lifecycle / error handling.

import Testing
import Foundation
import IntellectusLib
import ObserverSink
import PersistenceKit
@testable import MootManager

// MARK: - Helpers

/// A fresh temporary store path per test (so suites are independent).
private func makeTempStoreURL() -> URL {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("moot-mgr-test-\(UUID().uuidString)", isDirectory: true)
    return tmp.appendingPathComponent("stats.sqlite", isDirectory: false)
}

/// A started manager at a fresh temp store.
private func makeStartedManager(
    retentionWindow: TimeInterval = ManagerConfig.defaultRetentionWindow
) async throws -> MootManager {
    let config = ManagerConfig(storeURL: makeTempStoreURL(), retentionWindow: retentionWindow)
    let manager = MootManager(config: config)
    try await manager.start()
    return manager
}

// MARK: - End-to-end integration (the Phase-1 verify line)

// This suite mutates the PROCESS-GLOBAL `Intellectus` switch (install +
// setEnabled(true)). Other suites in this target now drive GLK provisioning,
// whose lifecycle verbs emit through the same global `Intellectus` sink — so a
// concurrent provision during this test's enabled window would land foreign
// telemetry in this test's store and inflate its counts. The whole test body
// runs under the process-wide `intellectusTestMutex` (IntellectusTestLock.swift)
// so it cannot interleave with the admin-plane GLK tests, which take the same
// lock. (`.serialized` alone only orders within one suite, not across suites —
// see the GLK telemetry-suite note.)
struct MootManagerIntegrationTests {

    @Test("End-to-end: monitoring ON → emit → land → retention → monitoring OFF → silent")
    func endToEndPipeline() async throws {
        try await withIntellectusLock {
        // Window is small so the cutoff math is easy to reason about in the test.
        let manager = try await makeStartedManager(retentionWindow: 1000)
        defer { Task { await manager.stop() } }

        // The consumer installs a PersistenceStatsSink against the MANAGER's store
        // and drives Intellectus.setEnabled from the flag — exactly the consumer
        // side from MANAGER_1.0_PLAN.md §3.
        let store = try await manager.statsStore()
        let dropboxID = "test-consumer-e2e"
        let estateID = "estate-e2e-1"
        let sink = PersistenceStatsSink(store: store, dropboxID: dropboxID)
        Intellectus.install(sink: sink)
        defer { Intellectus.setEnabled(false) }

        // STEP 1: manager sets monitoring ON. The consumer reads the flag and
        // enables its own IntellectusLib gate.
        try await manager.setMonitoring(true)
        Intellectus.setEnabled(try await manager.isMonitoring())
        #expect(Intellectus.isEnabled == true)

        // STEP 2: consumer reports a metric + an event (ts well after any cutoff
        // for the small window so they survive retention as the "new" rows).
        let newTs: Double = 10_000.0
        Intellectus.report(.metric(
            name: "e2e.metric", value: 1.0, tags: ["kit": "Test"], ts: newTs
        ))
        Intellectus.report(.event(
            kind: .capture, nounType: 3, rowID: UUID().uuidString,
            estate: estateID, ts: newTs
        ))

        // STEP 3: rows land in the store. The sink dispatches async I/O; poll.
        try await waitForCounts(store: store, dropboxID: dropboxID, metrics: 1, events: 1)
        let metricsAfterEmit = try await store.queryMetrics(dropboxID: dropboxID)
        let eventsAfterEmit = try await store.queryEvents(dropboxID: dropboxID)
        #expect(metricsAfterEmit.count == 1)
        #expect(eventsAfterEmit.count == 1)

        // Seed an OLD row directly (bypassing the sink, to control ts precisely)
        // so retention has something to roll off.
        try await store.insertMetric(name: "e2e.old", value: 9.0, tags: [:],
                                     ts: 100.0, dropboxID: dropboxID)
        try await store.insertEvent(kind: "think", nounType: 1, rowID: UUID().uuidString,
                                    estate: estateID, ts: 100.0, dropboxID: dropboxID)
        #expect(try await store.queryMetrics(dropboxID: dropboxID).count == 2)
        #expect(try await store.queryEvents(dropboxID: dropboxID).count == 2)

        // STEP 4: retention. now = 5000, window = 1000 → cutoff = 4000.
        // Old rows (ts=100) roll off; new rows (ts=10000) survive.
        let now = Date(timeIntervalSince1970: 5000.0)
        let deleted = try await manager.runRetention(now: now)
        #expect(deleted == 2, "Expected the two ts=100 rows rolled off")

        let metricsAfterRetention = try await store.queryMetrics(dropboxID: dropboxID)
        let eventsAfterRetention = try await store.queryEvents(dropboxID: dropboxID)
        #expect(metricsAfterRetention.count == 1, "new metric kept")
        #expect(eventsAfterRetention.count == 1, "new event kept")
        #expect(metricsAfterRetention.first?.name == "e2e.metric")

        // STEP 5: manager sets monitoring OFF. Consumer emission stops — even
        // with Intellectus still enabled, the sink reads the flag and discards.
        try await manager.setMonitoring(false)
        // Intellectus stays enabled to prove the STORE-level flag is the gate.
        Intellectus.report(.metric(name: "e2e.should.not.land", value: 2.0,
                                   tags: [:], ts: 20_000.0))
        Intellectus.report(.event(kind: .capture, nounType: 5,
                                  rowID: UUID().uuidString, estate: estateID, ts: 20_000.0))

        // Give the discarded dispatch time to (not) write, then assert no growth.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(try await store.queryMetrics(dropboxID: dropboxID).count == 1,
                "no new metric after monitoring OFF")
        #expect(try await store.queryEvents(dropboxID: dropboxID).count == 1,
                "no new event after monitoring OFF")
        }  // withIntellectusLock
    }

    /// Poll the store until the dropbox has at least the expected counts, or
    /// the deadline passes. PersistenceStatsSink dispatches inserts to async
    /// Tasks, so we must wait for them rather than assume synchronous writes.
    private func waitForCounts(
        store: StatsStore,
        dropboxID: String,
        metrics: Int,
        events: Int,
        timeoutMS: Int = 2000
    ) async throws {
        let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1000.0)
        while Date() < deadline {
            let m = try await store.queryMetrics(dropboxID: dropboxID).count
            let e = try await store.queryEvents(dropboxID: dropboxID).count
            if m >= metrics && e >= events { return }
            try await Task.sleep(nanoseconds: 25_000_000)   // 25 ms
        }
    }
}

// MARK: - Monitoring switch

struct MootManagerMonitoringTests {

    @Test("Monitoring switch round-trips through the store flag row")
    func monitoringRoundTrip() async throws {
        let manager = try await makeStartedManager()
        defer { Task { await manager.stop() } }

        // Default off (StatsStore seeds "0").
        #expect(try await manager.isMonitoring() == false)
        try await manager.setMonitoring(true)
        #expect(try await manager.isMonitoring() == true)
        try await manager.setMonitoring(false)
        #expect(try await manager.isMonitoring() == false)
    }

    @Test("Monitoring switch persists across a manager restart (same store path)")
    func monitoringPersistsAcrossRestart() async throws {
        // The manager's on/off switch is the persistent global signal — a
        // restart must not silently reset it (it would silence the whole fleet).
        let url = makeTempStoreURL()

        let first = MootManager(config: ManagerConfig(storeURL: url))
        try await first.start()
        try await first.setMonitoring(true)
        await first.stop()

        let second = MootManager(config: ManagerConfig(storeURL: url))
        try await second.start()
        defer { Task { await second.stop() } }
        #expect(try await second.isMonitoring() == true,
                "monitoring must survive a manager restart")
    }

    @Test("Operations before start() throw ManagerError.notStarted")
    func notStartedThrows() async throws {
        let manager = MootManager(config: ManagerConfig(storeURL: makeTempStoreURL()))
        await #expect(throws: ManagerError.notStarted) {
            try await manager.isMonitoring()
        }
        await #expect(throws: ManagerError.notStarted) {
            try await manager.setMonitoring(true)
        }
        await #expect(throws: ManagerError.notStarted) {
            _ = try await manager.runRetention(now: Date())
        }
    }
}

// MARK: - Retention

struct MootManagerRetentionTests {

    @Test("runRetention computes cutoff = now - window and rolls off old rows")
    func retentionCutoffMath() async throws {
        let manager = try await makeStartedManager(retentionWindow: 500)
        defer { Task { await manager.stop() } }
        let store = try await manager.statsStore()

        // now=2000, window=500 → cutoff=1500. ts<1500 rolls off.
        try await store.insertMetric(name: "old", value: 1, tags: [:], ts: 1000,
                                     dropboxID: "d")
        try await store.insertMetric(name: "keep", value: 2, tags: [:], ts: 1800,
                                     dropboxID: "d")
        let deleted = try await manager.runRetention(now: Date(timeIntervalSince1970: 2000))
        #expect(deleted == 1)
        let remaining = try await store.queryMetrics(dropboxID: "d")
        #expect(remaining.count == 1)
        #expect(remaining.first?.name == "keep")
    }
}

// MARK: - Status surface

struct MootManagerStatusTests {

    @Test("status groups by dropbox and by estate, lists recent events, reports health")
    func statusGrouping() async throws {
        let manager = try await makeStartedManager()
        defer { Task { await manager.stop() } }
        let store = try await manager.statsStore()

        // Two dropboxes, two estates.
        try await store.insertMetric(name: "m1", value: 1, tags: [:], ts: 100, dropboxID: "a")
        try await store.insertMetric(name: "m2", value: 1, tags: [:], ts: 101, dropboxID: "a")
        try await store.insertMetric(name: "m3", value: 1, tags: [:], ts: 102, dropboxID: "b")
        try await store.insertEvent(kind: "capture", nounType: 1, rowID: UUID().uuidString,
                                    estate: "estate-x", ts: 200, dropboxID: "a")
        try await store.insertEvent(kind: "think", nounType: 2, rowID: UUID().uuidString,
                                    estate: "estate-y", ts: 300, dropboxID: "b")

        let report = try await manager.status(now: Date(timeIntervalSince1970: 9999))

        #expect(report.totalMetrics == 3)
        #expect(report.totalEvents == 2)

        // By-dropbox (sorted: a, b).
        #expect(report.byDropbox.count == 2)
        #expect(report.byDropbox[0].key == "a")
        #expect(report.byDropbox[0].metricCount == 2)
        #expect(report.byDropbox[0].eventCount == 1)
        #expect(report.byDropbox[1].key == "b")
        #expect(report.byDropbox[1].metricCount == 1)
        #expect(report.byDropbox[1].eventCount == 1)

        // By-estate (events only; sorted: estate-x, estate-y).
        #expect(report.byEstate.count == 2)
        #expect(report.byEstate[0].key == "estate-x")
        #expect(report.byEstate[0].eventCount == 1)
        #expect(report.byEstate[1].key == "estate-y")
        #expect(report.byEstate[1].eventCount == 1)

        // Recent events newest-first: ts=300 (think) before ts=200 (capture).
        #expect(report.recentEvents.count == 2)
        #expect(report.recentEvents[0].kind == "think")
        #expect(report.recentEvents[1].kind == "capture")

        // Store health: SQLite backend supplies size/pages with the injected clock.
        let health = try #require(report.storeHealth)
        #expect(health.logicalSizeBytes > 0)
        #expect(health.capturedAt == Date(timeIntervalSince1970: 9999))

        // Text render is non-empty and reflects the monitoring state.
        let text = report.renderText()
        #expect(text.contains("monitoring: OFF"))
        #expect(text.contains("estate-x"))
    }

    @Test("status reflects monitoring ON and the recent-event limit")
    func statusRespectsLimit() async throws {
        let manager = try await makeStartedManager()
        defer { Task { await manager.stop() } }
        let store = try await manager.statsStore()
        try await manager.setMonitoring(true)

        for i in 0..<5 {
            try await store.insertEvent(kind: "capture", nounType: i, rowID: UUID().uuidString,
                                        estate: "e", ts: Double(100 + i), dropboxID: "d")
        }
        let report = try await manager.status(now: Date(timeIntervalSince1970: 1),
                                              recentEventLimit: 3)
        #expect(report.monitoringEnabled == true)
        #expect(report.totalEvents == 5)
        #expect(report.recentEvents.count == 3, "limit caps the recent list")
        // Newest first: ts=104 nounType=4 leads.
        #expect(report.recentEvents[0].nounType == 4)
    }
}

// MARK: - Config

struct ManagerConfigTests {

    @Test("Env override sets the store path verbatim")
    func envStorePathOverride() {
        let env = [ManagerConfig.storePathEnvKey: "/tmp/custom/stats.sqlite"]
        let config = ManagerConfig.fromEnvironment(env)
        #expect(config.storeURL.path == "/tmp/custom/stats.sqlite")
    }

    @Test("Default store path uses the moot-mgr subdirectory and file name")
    func defaultStorePath() {
        let config = ManagerConfig.fromEnvironment([:])
        #expect(config.storeURL.lastPathComponent == ManagerConfig.storeFileName)
        #expect(config.storeURL.deletingLastPathComponent().lastPathComponent
                == ManagerConfig.storeSubdirectory)
    }

    @Test("Retention window env parses positive seconds; rejects non-positive")
    func retentionWindowParsing() {
        #expect(ManagerConfig.fromEnvironment(
            [ManagerConfig.retentionWindowEnvKey: "3600"]).retentionWindow == 3600)
        // Non-positive / non-numeric fall back to the default.
        #expect(ManagerConfig.fromEnvironment(
            [ManagerConfig.retentionWindowEnvKey: "0"]).retentionWindow
            == ManagerConfig.defaultRetentionWindow)
        #expect(ManagerConfig.fromEnvironment(
            [ManagerConfig.retentionWindowEnvKey: "-5"]).retentionWindow
            == ManagerConfig.defaultRetentionWindow)
        #expect(ManagerConfig.fromEnvironment(
            [ManagerConfig.retentionWindowEnvKey: "abc"]).retentionWindow
            == ManagerConfig.defaultRetentionWindow)
    }
}

// MARK: - estatesPayload queue stats (TELEMETRY_QT)

struct EstatesPayloadQueueTests {

    @Test("estatesPayload returns nil queue when no queue metrics exist for the estate")
    func queueNilWhenNoSamples() async throws {
        let manager = try await makeStartedManager()
        defer { Task { await manager.stop() } }
        let store = try await manager.statsStore()
        let estateID = "estate-q-nil"

        // Insert only an event — no queue.* metrics for this estate.
        try await store.insertEvent(kind: "capture", nounType: 1,
                                    rowID: UUID().uuidString,
                                    estate: estateID, ts: 100, dropboxID: "d")

        let payload = try await manager.estatesPayload()
        let ep = payload.estates.first { $0.id == estateID }
        #expect(ep != nil, "estate '\(estateID)' must appear in payload")
        #expect(ep?.queue == nil,
                "queue must be nil when no queue metric samples exist for the estate")
    }

    @Test("estatesPayload populates queue struct from latest queue metrics")
    func queuePopulatedFromMetrics() async throws {
        let manager = try await makeStartedManager()
        defer { Task { await manager.stop() } }
        let store = try await manager.statsStore()
        let estateID = "estate-q-data"
        let tags = ["estate": estateID, "kit": "QueueKit"]

        // Insert queue.* metrics and an event so the estate appears in the payload.
        try await store.insertMetric(name: "queue.depth", value: 7.0, tags: tags,
                                     ts: 200, dropboxID: "d")
        try await store.insertMetric(name: "queue.drain_count", value: 3.0, tags: tags,
                                     ts: 200, dropboxID: "d")
        try await store.insertMetric(name: "queue.idle_nonempty", value: 1.0, tags: tags,
                                     ts: 200, dropboxID: "d")
        try await store.insertEvent(kind: "capture", nounType: 1,
                                    rowID: UUID().uuidString,
                                    estate: estateID, ts: 200, dropboxID: "d")

        let payload = try await manager.estatesPayload()
        guard let ep = payload.estates.first(where: { $0.id == estateID }) else {
            Issue.record("estate '\(estateID)' missing from payload")
            return
        }
        guard let q = ep.queue else {
            Issue.record("queue must be non-nil for estate with queue metric samples")
            return
        }
        #expect(q.depth == 7.0, "queue.depth must be 7.0; got \(q.depth as Any)")
        #expect(q.drainCount == 3.0, "queue.drain_count must be 3.0; got \(q.drainCount as Any)")
        // idle_nonempty 1.0 projects to true
        #expect(q.idleNonempty == true,
                "idle_nonempty 1.0 must project to true; got \(q.idleNonempty as Any)")
    }

    @Test("estatesPayload maps idle_nonempty 0.0 to false")
    func idleNonemptyZeroIsFalse() async throws {
        let manager = try await makeStartedManager()
        defer { Task { await manager.stop() } }
        let store = try await manager.statsStore()
        let estateID = "estate-q-idle-false"
        let tags = ["estate": estateID, "kit": "QueueKit"]

        try await store.insertMetric(name: "queue.idle_nonempty", value: 0.0, tags: tags,
                                     ts: 100, dropboxID: "d")
        try await store.insertEvent(kind: "capture", nounType: 1,
                                    rowID: UUID().uuidString,
                                    estate: estateID, ts: 100, dropboxID: "d")

        let payload = try await manager.estatesPayload()
        let q = payload.estates.first { $0.id == estateID }?.queue
        #expect(q?.idleNonempty == false, "idle_nonempty 0.0 must project to false")
    }
}

// MARK: - CLI parsing + dispatch

struct ManagerCLITests {

    @Test("parse maps the command surface correctly")
    func parseCommands() {
        #expect(ManagerCLI.parse([]) == .help)
        #expect(ManagerCLI.parse(["help"]) == .help)
        #expect(ManagerCLI.parse(["--help"]) == .help)
        #expect(ManagerCLI.parse(["status"]) == .status)
        #expect(ManagerCLI.parse(["serve"]) == .serve)
        #expect(ManagerCLI.parse(["monitoring", "on"]) == .monitoringOn)
        #expect(ManagerCLI.parse(["monitoring", "off"]) == .monitoringOff)
        #expect(ManagerCLI.parse(["monitoring", "status"]) == .monitoringStatus)
        #expect(ManagerCLI.parse(["retention", "run"]) == .retentionRun)
    }

    @Test("parse rejects malformed commands")
    func parseRejects() {
        #expect(ManagerCLI.parse(["monitoring"]) == nil)
        #expect(ManagerCLI.parse(["monitoring", "bogus"]) == nil)
        #expect(ManagerCLI.parse(["retention"]) == nil)
        #expect(ManagerCLI.parse(["retention", "bogus"]) == nil)
        #expect(ManagerCLI.parse(["nonsense"]) == nil)
    }

    @Test("run drives the manager: monitoring on/off/status and status")
    func runDispatch() async throws {
        let manager = try await makeStartedManager()
        defer { Task { await manager.stop() } }
        let now = Date(timeIntervalSince1970: 1234)

        let on = try await ManagerCLI.run(.monitoringOn, manager: manager, now: now)
        #expect(on == "monitoring: ON")
        #expect(try await manager.isMonitoring() == true)

        let statusLine = try await ManagerCLI.run(.monitoringStatus, manager: manager, now: now)
        #expect(statusLine == "monitoring: ON")

        let off = try await ManagerCLI.run(.monitoringOff, manager: manager, now: now)
        #expect(off == "monitoring: OFF")
        #expect(try await manager.isMonitoring() == false)

        let full = try await ManagerCLI.run(.status, manager: manager, now: now)
        #expect(full.contains("moot-mgr status"))

        let retention = try await ManagerCLI.run(.retentionRun, manager: manager, now: now)
        #expect(retention.hasPrefix("retention: rolled off "))
    }
}
