// ObserverTests.swift
//
// Force-tests for the resident observer program (DEBT-3, Bob's ruling).
// Bob's four required proofs, here at the AriaResident composition layer:
//   1. observer enabled  → sample recorded in the bounded window
//   2. observer disabled → no crash + explicit off state (not silent)
//   3. enable decision    → env ARIA_MCP_OBSERVER OR store flag
//   4. bounded window     → overflow evicts oldest, bound holds
//
// The "sample emitted → sink receives" and "topology worker consumes →
// visible output updated" proofs live at their own layers: the StatsSink
// receive path is force-tested in ObserverSinkConformanceTests; the topology
// worker's snapshot write + /api/graph read is force-tested in the governor
// and HTTPServer suites. This suite proves the observer program glue: the
// window, the enable decision, and the explicit off state.
//
// These tests modify the process-wide Intellectus global; the install suite
// runs serially so the global gate is not raced.

import Testing
import Foundation
import IntellectusLib
import ObserverSink
@testable import AriaResident

// MARK: - shouldEnable / env decision (pure, no global state)

@Suite("Observer.shouldEnable — enable decision")
struct ObserverShouldEnableTests {

    @Test("store flag on enables (env absent)")
    func storeFlagOnEnables() {
        #expect(Observer.shouldEnable(env: [:], storeFlag: true) == true)
    }

    @Test("store flag off + env absent disables")
    func bothOffDisables() {
        #expect(Observer.shouldEnable(env: [:], storeFlag: false) == false)
    }

    @Test("ARIA_MCP_OBSERVER truthy forces enable even when store flag is off")
    func envOptInForcesEnable() {
        for truthy in ["1", "true", "TRUE", "yes", "On"] {
            let env = ["ARIA_MCP_OBSERVER": truthy]
            #expect(Observer.shouldEnable(env: env, storeFlag: false) == true,
                    "ARIA_MCP_OBSERVER=\(truthy) must enable")
        }
    }

    @Test("ARIA_MCP_OBSERVER falsey/garbage does not enable on its own")
    func envFalseyDoesNotEnable() {
        for falsey in ["0", "false", "no", "off", "", "banana"] {
            let env = ["ARIA_MCP_OBSERVER": falsey]
            #expect(Observer.shouldEnable(env: env, storeFlag: false) == false,
                    "ARIA_MCP_OBSERVER=\(falsey) must not enable on its own")
        }
    }
}

// MARK: - Window + gate (modifies the Intellectus global → serialized)

@Suite("Observer — bounded window + gate", .serialized)
struct ObserverWindowTests {

    /// Restore the global Intellectus state after each window test.
    private func restoreGlobal() {
        Intellectus.setEnabled(false)
        Intellectus.install(sink: NoOpSink.shared)
    }

    @Test("FORCE: observer enabled → sample recorded in the window")
    func enabledRecordsInWindow() async throws {
        try await intellectusGlobalGate.withLock {
            let observer = Observer(forward: nil, windowCapacity: 16)
            observer.install()
            observer.setEnabled(true)
            defer { restoreGlobal() }

            #expect(observer.isEnabled == true)
            Intellectus.report(.metric(name: "obs.on", value: 1.0, tags: [:], ts: 42.0))
            #expect(observer.window.count == 1)
            #expect(observer.window.totalReceived == 1)
            #expect(observer.window.snapshot().first?.ts == 42.0)
        }
    }

    @Test("FORCE: observer disabled → no sample recorded + explicit off state")
    func disabledIsExplicitOffAndDoesNotRecord() async throws {
        try await intellectusGlobalGate.withLock {
            let observer = Observer(forward: nil, windowCapacity: 16)
            observer.install()
            observer.setEnabled(false)
            defer { restoreGlobal() }

            // Explicit, observable off — not silent.
            #expect(observer.isEnabled == false)
            // Reporting while off must not crash and must not record.
            Intellectus.report(.metric(name: "obs.off", value: 1.0, tags: [:], ts: 0.0))
            #expect(observer.window.count == 0)
            #expect(observer.window.totalReceived == 0)
        }
    }

    @Test("FORCE: bounded window overflow evicts oldest, bound holds")
    func boundedWindowHolds() async throws {
        try await intellectusGlobalGate.withLock {
            let observer = Observer(forward: nil, windowCapacity: 3)
            observer.install()
            observer.setEnabled(true)
            defer { restoreGlobal() }

            for i in 0..<10 {
                Intellectus.report(.metric(name: "obs.flood", value: Double(i), tags: [:], ts: Double(i)))
            }
            // Bound holds regardless of volume.
            #expect(observer.window.count == 3)
            #expect(observer.window.totalReceived == 10)
            let snap = observer.window.snapshot()
            #expect(snap.first?.ts == 7.0)  // oldest retained (0..6 evicted)
            #expect(snap.last?.ts == 9.0)   // newest
        }
    }

    @Test("toggling off after on stops recording (explicit off mid-flight)")
    func toggleOffStopsRecording() async throws {
        try await intellectusGlobalGate.withLock {
            let observer = Observer(forward: nil, windowCapacity: 16)
            observer.install()
            observer.setEnabled(true)
            defer { restoreGlobal() }

            Intellectus.report(.metric(name: "before", value: 1.0, tags: [:], ts: 1.0))
            #expect(observer.window.count == 1)

            observer.setEnabled(false)
            #expect(observer.isEnabled == false)
            Intellectus.report(.metric(name: "after", value: 2.0, tags: [:], ts: 2.0))
            #expect(observer.window.count == 1, "no new sample recorded after disable")
        }
    }
}

// MARK: - Window forwards to durable store (window + persistence in one sink)

@Suite("Observer — window forwards to store", .serialized)
struct ObserverForwardTests {

    private func makeTempStoreURL() -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("observertest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp.appendingPathComponent("stats.sqlite")
    }

    @Test("FORCE: enabled observer records in window AND persists to the store")
    func recordsAndPersists() async throws {
        try await intellectusGlobalGate.withLock {
            let store = try StatsStore(url: makeTempStoreURL())
            try await store.open()
            try await store.setMonitoringEnabled(true)
            let observer = Observer(forward: PersistenceStatsSink(store: store, dropboxID: "obs-test"))
            observer.install()
            observer.setEnabled(true)
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
                Task { await store.close() }
            }

            let name = "obs.forward.\(UUID().uuidString.prefix(8))"
            Intellectus.report(.metric(name: name, value: 7.0, tags: [:], ts: 1_700_000_200.0))

            // In-process window is immediate.
            #expect(observer.window.count == 1)

            // Durable store write is async (PersistenceStatsSink dispatches a Task).
            try await Task.sleep(nanoseconds: 200_000_000)
            let rows = try await store.queryMetricsByNames([name])
            #expect(rows.count == 1, "forwarded sample must persist to the store")
            #expect(rows.first?.value == 7.0)
        }
    }
}
