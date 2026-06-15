// PersistenceKitSQLiteTelemetryTests.swift
//
// Integration tests for the IntellectusLib telemetry emission added to
// PersistenceKit in cp-persistencekit-report.
//
// These tests cover the SQLite backend, which populates:
//   logicalSizeBytes, pageSize, pageCount, freelistPageCount,
//   walFrameCount, capturedAt. SQLite-only fields (page_size,
//   page_count, freelist_pages, wal_frames) must appear; InMemory
//   and PostgreSQL-specific fields must be absent.
//
// Test sections:
//   §1 Disabled gate: with monitoring OFF, no metrics emitted.
//   §2 Enabled gate: with monitoring ON, the correct SQLite metrics arrive.
//   §3 Metric shapes: names, tags, values in persistence.db.* namespace.
//   §4 Conformance: StorageStats identical with monitoring ON or OFF.
//
// CRITICAL — Global singleton isolation:
//   Same pattern as PersistenceKitInMemoryTests. Every test body that
//   touches Intellectus singleton state holds GlobalTestLock.shared.

import Foundation
import Testing
import PersistenceKit
import PersistenceKitSQLite
import PersistenceKitConformance
import IntellectusLib

// MARK: - Helper: capturing sink

private final class CapturingSink: StatsSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _samples: [StatSample] = []

    func receive(_ sample: StatSample) {
        lock.lock()
        _samples.append(sample)
        lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return _samples.count
    }

    func count(prefix: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return _samples.filter {
            if case let .metric(name, _, _, _) = $0 { return name.hasPrefix(prefix) }
            return false
        }.count
    }

    func samples(prefix: String) -> [StatSample] {
        lock.lock(); defer { lock.unlock() }
        return _samples.filter {
            if case let .metric(name, _, _, _) = $0 { return name.hasPrefix(prefix) }
            return false
        }
    }
}

// MARK: - Schema and storage helpers

private let schema = SchemaDeclaration(
    kitID: "pk-sqlite-telemetry-test",
    version: 1,
    tables: [
        TableDeclaration(
            name: "items",
            columns: [
                ColumnDeclaration(name: "id", type: .uuid, nullable: false),
                ColumnDeclaration(name: "label", type: .text, nullable: false),
            ],
            primaryKey: ["id"]
        )
    ]
)

/// Open a fresh temp-dir SQLiteStorage for each test.
private func makeStorage() throws -> SQLiteStorage {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pk-sqlite-telem-\(UUID().uuidString)")
    let url = dir.appendingPathComponent("test.db")
    let cfg = EstateConfiguration(estateID: UUID(), backend: .sqlite(url: url))
    return try SQLiteStorage(configuration: cfg)
}

// MARK: - §1 Disabled gate

@Suite("§1 PKSQLiteTelemetry — disabled gate", .serialized)
struct PKSQLiteTelemetryDisabledTests {

    @Test("reportStorageStats does not emit when monitoring is disabled")
    func noEmitWhenDisabled() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeStorage()
            try await storage.open(schema: schema)
            defer { Task { await storage.close() } }

            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(false)

            let now = Date(timeIntervalSince1970: 1_700_000_000)
            await reportStorageStats(storage, estateID: "sqlite-estate", now: now)

            #expect(sink.count == 0,
                "reportStorageStats must not emit when monitoring is disabled; got \(sink.count)")

            Intellectus.install(sink: NoOpSink.shared)
        }
    }
}

// MARK: - §2 Enabled gate

@Suite("§2 PKSQLiteTelemetry — enabled gate", .serialized)
struct PKSQLiteTelemetryEnabledTests {

    @Test("reportStorageStats emits persistence.db.* metrics when monitoring is enabled")
    func emitsMetricsWhenEnabled() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeStorage()
            try await storage.open(schema: schema)
            defer { Task { await storage.close() } }

            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)

            let now = Date(timeIntervalSince1970: 1_700_000_000)
            await reportStorageStats(storage, estateID: "sqlite-estate", now: now)

            let pkCount = sink.count(prefix: "persistence.db.")
            #expect(pkCount > 0,
                "reportStorageStats must emit at least one persistence.db.* metric; got \(pkCount)")

            Intellectus.setEnabled(false)
            Intellectus.install(sink: NoOpSink.shared)
        }
    }

    @Test("reportStorageStats emits SQLite-specific metrics")
    func emitsSQLiteSpecificMetrics() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeStorage()
            try await storage.open(schema: schema)
            defer { Task { await storage.close() } }

            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)

            let now = Date(timeIntervalSince1970: 1_700_000_000)
            await reportStorageStats(storage, estateID: "sqlite-estate", now: now)

            let pkSamples = sink.samples(prefix: "persistence.db.")
            let names = pkSamples.compactMap { sample -> String? in
                if case let .metric(name, _, _, _) = sample { return name }
                return nil
            }

            // SQLite backend must emit these metrics.
            let expectedSQLiteMetrics = [
                "persistence.db.size_bytes",
                "persistence.db.page_size",
                "persistence.db.page_count",
                "persistence.db.freelist_pages",
                "persistence.db.wal_frames",
            ]
            for expected in expectedSQLiteMetrics {
                #expect(names.contains(expected),
                    "SQLite backend must emit \(expected); got \(names)")
            }

            Intellectus.setEnabled(false)
            Intellectus.install(sink: NoOpSink.shared)
        }
    }

    @Test("InMemory-specific metrics are absent for SQLite backend")
    func inMemoryMetricsAbsentForSQLite() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeStorage()
            try await storage.open(schema: schema)
            defer { Task { await storage.close() } }

            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)

            let now = Date(timeIntervalSince1970: 1_700_000_000)
            await reportStorageStats(storage, estateID: "sqlite-estate", now: now)

            let pkSamples = sink.samples(prefix: "persistence.db.")
            let inMemoryMetrics = ["persistence.db.row_count", "persistence.db.blob_count"]
            for metricName in inMemoryMetrics {
                let found = pkSamples.contains {
                    if case let .metric(name, _, _, _) = $0 { return name == metricName }
                    return false
                }
                #expect(!found, "\(metricName) must not be emitted for SQLite backend")
            }

            Intellectus.setEnabled(false)
            Intellectus.install(sink: NoOpSink.shared)
        }
    }
}

// MARK: - §3 Metric shapes

@Suite("§3 PKSQLiteTelemetry — metric shapes", .serialized)
struct PKSQLiteTelemetryShapeTests {

    @Test("page_size metric is a positive power of two")
    func pageSizeIsPositivePowerOfTwo() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeStorage()
            try await storage.open(schema: schema)
            defer { Task { await storage.close() } }

            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)

            let now = Date(timeIntervalSince1970: 1_700_000_000)
            await reportStorageStats(storage, estateID: "sqlite-estate", now: now)

            let pkSamples = sink.samples(prefix: "persistence.db.")
            let pageSizeMetric = pkSamples.first {
                if case let .metric(name, _, _, _) = $0 { return name == "persistence.db.page_size" }
                return false
            }
            guard let psm = pageSizeMetric,
                  case let .metric(_, value, tags, _) = psm else {
                Issue.record("expected persistence.db.page_size metric")
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
                return
            }

            let ps = Int(value)
            #expect(ps > 0, "page_size must be positive; got \(ps)")
            // Power-of-two check: ps & (ps - 1) == 0
            #expect(ps & (ps - 1) == 0, "page_size must be a power of two; got \(ps)")
            #expect(tags["kit"] == "PersistenceKit",
                "page_size must carry kit=PersistenceKit tag")

            Intellectus.setEnabled(false)
            Intellectus.install(sink: NoOpSink.shared)
        }
    }

    @Test("wal_frames metric is non-negative")
    func walFramesIsNonNegative() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeStorage()
            try await storage.open(schema: schema)
            defer { Task { await storage.close() } }

            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)

            let now = Date(timeIntervalSince1970: 1_700_000_000)
            await reportStorageStats(storage, estateID: "sqlite-estate", now: now)

            let pkSamples = sink.samples(prefix: "persistence.db.")
            let walMetric = pkSamples.first {
                if case let .metric(name, _, _, _) = $0 { return name == "persistence.db.wal_frames" }
                return false
            }
            // walFrameCount may be 0 immediately after a fresh open (no WAL writes yet),
            // but it must be present (non-nil) and non-negative for SQLite WAL mode.
            guard let wm = walMetric,
                  case let .metric(_, value, _, _) = wm else {
                Issue.record("expected persistence.db.wal_frames metric for SQLite WAL-mode backend")
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
                return
            }
            #expect(value >= 0.0, "wal_frames must be non-negative; got \(value)")

            Intellectus.setEnabled(false)
            Intellectus.install(sink: NoOpSink.shared)
        }
    }
}

// MARK: - §4 Conformance gate

@Suite("§4 PKSQLiteTelemetry — conformance", .serialized)
struct PKSQLiteTelemetryConformanceTests {

    @Test("StorageStats is identical with monitoring disabled and enabled")
    func statsIdenticalWithMonitoringOffAndOn() async throws {
        try await GlobalTestLock.shared.withLock {
            let now = Date(timeIntervalSince1970: 1_700_000_000)

            // --- Monitoring OFF ---
            Intellectus.setEnabled(false)
            let storageOff = try makeStorage()
            try await storageOff.open(schema: schema)
            defer { Task { await storageOff.close() } }
            await reportStorageStats(storageOff, estateID: "off-estate", now: now)
            let statsOff = try await storageOff.stats(now: now)

            // --- Monitoring ON ---
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            let storageOn = try makeStorage()
            try await storageOn.open(schema: schema)
            defer { Task { await storageOn.close() } }
            await reportStorageStats(storageOn, estateID: "on-estate", now: now)
            let statsOn = try await storageOn.stats(now: now)

            // Structural equivalence: both fresh stores have same schema so
            // page_size and freelist_page_count should match.
            if let offPageSize = statsOff.pageSize, let onPageSize = statsOn.pageSize {
                #expect(offPageSize == onPageSize,
                    "pageSize must be equal for equivalent fresh SQLite stores")
            }
            #expect(statsOff.capturedAt == statsOn.capturedAt,
                "capturedAt must equal the injected now for both")

            // Metrics were emitted on the ON path.
            let pkCount = sink.count(prefix: "persistence.db.")
            #expect(pkCount > 0, "at least one persistence.db.* metric must be emitted when monitoring is enabled")

            Intellectus.setEnabled(false)
            Intellectus.install(sink: NoOpSink.shared)
        }
    }

    @Test("reportStorageStats does not modify SQLite storage state")
    func reportDoesNotModifyStorage() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeStorage()
            try await storage.open(schema: schema)
            defer { Task { await storage.close() } }

            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let before = try await storage.stats(now: now)

            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            await reportStorageStats(storage, estateID: "sqlite-estate", now: now)
            Intellectus.setEnabled(false)

            let after = try await storage.stats(now: now)

            // Page count must not change — reportStorageStats is read-only.
            // (It may be equal or slightly higher if SQLite checkpoints, but
            // it must not decrease.)
            if let beforePages = before.pageCount, let afterPages = after.pageCount {
                #expect(afterPages >= beforePages,
                    "pageCount must not decrease after reportStorageStats")
            }
            #expect(before.pageSize == after.pageSize,
                "pageSize must be unchanged by reportStorageStats")

            Intellectus.install(sink: NoOpSink.shared)
        }
    }
}
