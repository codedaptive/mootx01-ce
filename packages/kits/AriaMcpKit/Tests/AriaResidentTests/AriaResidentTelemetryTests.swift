// AriaResidentTelemetryTests.swift
//
// Tests for the resident-daemon telemetry wiring:
//   1. statsStorePathFromEnv — env override, useDefault=true default path, useDefault=false nil.
//   2. installManagerTelemetry with a real path: wires the sink so a reported sample
//      lands in the stats store (enabled sink persists samples).
//   3. installManagerTelemetry with nil/empty path: returns nil. The tests assert
//      only the nil return value; they do not inspect the installed sink or prove
//      no-op behavior of the enabled gate.
//
// Both-ports parity note:
//   The Rust port's stats_store_path_from_env() is exercised by the Rust
//   runtime tests in packages/kits/AriaMcpKit/rust/tests/runtime_tests.rs (same three
//   scenarios: explicit env, default, absent).

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

// MARK: - statsStorePathFromEnv

@Suite("AriaResident.statsStorePathFromEnv")
struct StatsStorePathFromEnvTests {

    @Test("env var override takes precedence in both modes")
    func envVarOverrideTakesPrecedence() {
        let explicit = "/tmp/my-stats.sqlite"
        let env = ["ARIA_MCP_STATS_STORE": explicit]

        // Override is returned regardless of useDefault.
        #expect(AriaResident.statsStorePathFromEnv(env: env, useDefault: false) == explicit)
        #expect(AriaResident.statsStorePathFromEnv(env: env, useDefault: true) == explicit)
    }

    @Test("useDefault=false with no env var returns nil (stdio opt-in)")
    func noEnvAndNoDefaultReturnsNil() {
        let result = AriaResident.statsStorePathFromEnv(env: [:], useDefault: false)
        #expect(result == nil, "stdio mode must return nil when env var absent")
    }

    @Test("useDefault=true with no env var returns the moot-mgr platform default path")
    func useDefaultReturnsDefaultPath() {
        let result = AriaResident.statsStorePathFromEnv(env: [:], useDefault: true)
        // Must be non-nil and contain the canonical moot-mgr path segments.
        #expect(result != nil,
                "resident default path must be non-nil when useDefault=true")
        #expect(result?.hasSuffix("moot-mgr/stats.sqlite") == true,
                "resident default path must end with moot-mgr/stats.sqlite, got: \(result ?? "nil")")
        // Must contain the com.mootx01.ce bundle-ID segment.
        #expect(result?.contains("com.mootx01.ce") == true,
                "resident default path must contain com.mootx01.ce, got: \(result ?? "nil")")
    }

    @Test("empty env var string is treated as absent (falls through to default or nil)")
    func emptyEnvVarIsTreatedAsAbsent() {
        let env = ["ARIA_MCP_STATS_STORE": ""]
        // stdio: nil; resident: default path.
        #expect(AriaResident.statsStorePathFromEnv(env: env, useDefault: false) == nil)
        let defaultResult = AriaResident.statsStorePathFromEnv(env: env, useDefault: true)
        #expect(defaultResult != nil, "empty env var with useDefault=true must return the default path")
        #expect(defaultResult?.hasSuffix("moot-mgr/stats.sqlite") == true)
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
        try await intellectusGlobalGate.withLock {
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
        try await intellectusGlobalGate.withLock {
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
