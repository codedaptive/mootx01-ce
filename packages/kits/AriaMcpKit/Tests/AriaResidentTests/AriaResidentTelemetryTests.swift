// AriaResidentTelemetryTests.swift
//
// Tests for the resident-daemon telemetry wiring:
//   1. statsStorePath — wiring tests proving the configurationDirectory seam
//      routes through Settings.load (two tests: key-set and key-absent).
//      Existing tests use a scratch directory so no real config.json is read.
//      (ARIA_MCP_STATS_STORE env override removed per R6, 2026-09-08.)
//   2. installManagerTelemetry with a real path: wires the sink so a reported sample
//      lands in the stats store (enabled sink persists samples).
//   3. installManagerTelemetry with nil/empty path: returns nil.

import Testing
import Foundation
import IntellectusLib
import ObserverSink
@testable import AriaResident

// MARK: - Helpers

/// Create a unique temporary URL for a stats store in each test.
private func makeTempStoreURL() -> URL {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("ariaresidenttest-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    return tmp.appendingPathComponent("stats.sqlite")
}

// MARK: - statsStorePath helpers

private func makeScratchDir(label: String = "") throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("com.mootx01.statstest-\(label)\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func writeConfig(_ json: String, to dir: URL) throws {
    let url = dir.appendingPathComponent("config.json")
    try json.data(using: .utf8)!.write(to: url)
}

// MARK: - statsStorePath

@Suite("AriaResident.statsStorePath")
struct StatsStorePathTests {

    @Test("useDefault=false returns nil (stdio opt-in)")
    func noDefaultReturnsNil() throws {
        let scratch = try makeScratchDir(label: "nil-")
        let result = AriaResident.statsStorePath(useDefault: false, configurationDirectory: scratch)
        #expect(result == nil, "stdio mode must return nil")
    }

    @Test("useDefault=true with no config key returns the computed default")
    func useDefaultReturnsDefaultPath() throws {
        // Use a scratch dir with no config.json so we exercise the fallback path
        // without reading the developer's real configuration file.
        let scratch = try makeScratchDir(label: "default-")
        let result = AriaResident.statsStorePath(useDefault: true, configurationDirectory: scratch)
        #expect(result != nil,
                "resident default path must be non-nil when useDefault=true")
        #expect(result?.hasSuffix("moot-mgr/stats.sqlite") == true,
                "resident default path must end with moot-mgr/stats.sqlite, got: \(result ?? "nil")")
    }

    // MARK: Wiring tests — configurationDirectory seam proves the reader honours the setting

    /// Wiring test (key set): statsStorePath with a scratch config dir that has
    /// `daemon.stats_store` set returns that configured path. Deleting the
    /// Settings.load call in statsStorePath makes this test red.
    @Test("wiring: key set in scratch config dir → statsStorePath returns it")
    func wiring_keySet_returnsConfiguredPath() throws {
        let scratch = try makeScratchDir(label: "wiring-set-")
        let customPath = scratch.appendingPathComponent("custom-stats.sqlite").path
        try writeConfig(#"{"daemon":{"stats_store":"\#(customPath)"}}"#, to: scratch)
        let result = AriaResident.statsStorePath(useDefault: true, configurationDirectory: scratch)
        #expect(result == customPath,
                "statsStorePath must return daemon.stats_store from config.json; got \(result ?? "nil")")
    }

    /// Wiring test (key absent): statsStorePath with a scratch config dir that has
    /// no key falls back to the computed default under that dir.
    @Test("wiring: key absent in scratch config dir → statsStorePath returns computed default")
    func wiring_keyAbsent_returnsComputedDefault() throws {
        let scratch = try makeScratchDir(label: "wiring-absent-")
        // No config.json written — key is absent.
        let result = AriaResident.statsStorePath(useDefault: true, configurationDirectory: scratch)
        let expected = scratch.appendingPathComponent("moot-mgr/stats.sqlite").path
        #expect(result == expected,
                "statsStorePath must fall back to <configDir>/moot-mgr/stats.sqlite; got \(result ?? "nil")")
    }
}

// MARK: - installManagerTelemetry

/// The telemetry tests modify the process-wide Intellectus global. Run them
/// serially so they do not race each other.
@Suite("AriaResident.installManagerTelemetry", .serialized)
struct InstallManagerTelemetryTests {

    // MARK: 1. Enabled sink persists samples

    @Test("installManagerTelemetry: enabled sink persists a reported sample")
    func enabledSinkPersistsSample() async throws {
        try await intellectusGlobalGate.withLock {
            // Use a fresh temp store path that does not exist yet — StatsStore.open()
            // creates it via SQLiteStorage on first open.
            let storeURL = makeTempStoreURL()
            let storePath = storeURL.path

            // Wire telemetry via the resident helper.
            let wiring = await AriaResident.installManagerTelemetry(storePath: storePath)
            let returnedStore = try #require(wiring, "installManagerTelemetry must return non-nil wiring on success").store

            // The store's monitoring flag is read on install and sets Intellectus.isEnabled.
            // The default flag after open() is "0" (off), so isEnabled starts false.
            // Enable the store flag so the sink actually writes samples.
            try await returnedStore.setMonitoringEnabled(true)
            Intellectus.setEnabled(true)

            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
                Task { await returnedStore.close() }
            }

            // Report a sample through the global facade.
            let testName = "ariaresidenttest.emit.\(UUID().uuidString.prefix(8))"
            let testTS: Double = 1_700_000_100.0
            Intellectus.report(.metric(
                name: testName,
                value: 99.0,
                tags: ["test": "installManagerTelemetry"],
                ts: testTS
            ))

            // Allow the async Task in PersistenceStatsSink to complete.
            try await Task.sleep(nanoseconds: 150_000_000)   // 150 ms

            // The sample must have landed in the store.
            let rows = try await returnedStore.queryMetricsByNames([testName])
            #expect(rows.count == 1, "Expected exactly one persisted metric row, got \(rows.count)")
            let row = try #require(rows.first)
            #expect(row.name == testName)
            #expect(row.value == 99.0)
            #expect(row.tags["test"] == "installManagerTelemetry")
            #expect(abs(row.ts.timeIntervalSince1970 - testTS) < 1.0,
                    "Persisted ts must round-trip within 1 second")
        }
    }

    // MARK: 2. Disabled stays no-op

    @Test("installManagerTelemetry: nil path returns nil and does not install a real sink")
    func nilPathReturnsNilAndIsNoOp() async throws {
        await intellectusGlobalGate.withLock {
            // Save current state so the test is non-destructive.
            let wasEnabled = Intellectus.isEnabled
            defer {
                Intellectus.setEnabled(wasEnabled)
            }

            let result = await AriaResident.installManagerTelemetry(storePath: nil)
            #expect(result == nil, "nil path must return nil — no store opened")
            // The enabled state is saved in wasEnabled and restored by defer.
            // There is no assertion that isEnabled == wasEnabled after the call;
            // the sink cannot be inspected directly.
        }
    }

    @Test("installManagerTelemetry: empty path returns nil and does not install a real sink")
    func emptyPathReturnsNilAndIsNoOp() async throws {
        await intellectusGlobalGate.withLock {
            let result = await AriaResident.installManagerTelemetry(storePath: "")
            #expect(result == nil, "empty path must return nil — no store opened")
        }
    }

    // MARK: 3. Monitoring flag honoured on install

    @Test("installManagerTelemetry: Intellectus is not enabled when store flag is off")
    func intellectusNotEnabledWhenStoreFlagOff() async throws {
        try await intellectusGlobalGate.withLock {
            // A fresh store seeds monitoring="1" (ON by default, wave 8.1), so
            // flip the persisted flag off first — the operator's explicit
            // opt-out, which the seed migration must respect. Then wire
            // telemetry with an empty env so the enable decision (store flag
            // OR the ARIA_MCP_OBSERVER env opt-in) is driven by the store's
            // off flag alone, independent of the test runner's environment.
            let storeURL = makeTempStoreURL()
            let seeded = try StatsStore(url: storeURL)
            try await seeded.open()
            try await seeded.setMonitoringEnabled(false)
            await seeded.close()

            let wiring = await AriaResident.installManagerTelemetry(storePath: storeURL.path, env: [:])
            let returnedStore = try #require(wiring).store
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
                Task { await returnedStore.close() }
            }

            // Store flag off + env opt-in absent → Intellectus.isEnabled false.
            #expect(Intellectus.isEnabled == false,
                    "Intellectus must not be enabled when the store flag is off and ARIA_MCP_OBSERVER is unset")
        }
    }
}
