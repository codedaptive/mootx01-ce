// PersistenceKitTelemetryTests.swift
//
// Integration tests for the IntellectusLib telemetry emission added to
// PersistenceKit in cp-persistencekit-report.
//
// These tests cover the InMemory backend, which populates:
//   rowCount, blobCount, transactionRollbackCount,
//   logicalSizeBytes, capturedAt.
//
// Test sections:
//   §1 Disabled gate: with monitoring OFF, reportStorageStats must not
//      emit any metrics. StorageStats result must be unchanged.
//   §2 Enabled gate: with monitoring ON and a capturing sink, the
//      correct metrics arrive with expected shapes.
//   §3 Metric shapes: names, tags, and values in the
//      persistence.db.* namespace.
//   §4 Conformance: StorageStats is identical whether or not
//      monitoring is enabled — telemetry MUST NOT affect storage state.
//
// CRITICAL — Global singleton isolation:
//   Intellectus is a process-wide singleton (enabled flag + installed sink).
//   Swift Testing runs suites in PARALLEL by default. Tests that toggle
//   the enabled flag or install a capturing sink will corrupt each other's
//   exact-count assertions unless they are all serialized under one lock.
//
//   Strategy: every test body that touches the Intellectus singleton OR
//   calls reportStorageStats holds GlobalTestLock.shared for its entire
//   duration. The @Suite(.serialized) annotation prevents concurrent
//   execution WITHIN a suite. GlobalTestLock prevents interleaving
//   ACROSS suites in the same test binary.

import Foundation
import Testing
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitConformance
import IntellectusLib

// MARK: - Helper: capturing sink

/// A sink that records every received StatSample. Thread-safe via NSLock.
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

    /// Count of samples whose name starts with the given prefix.
    func count(prefix: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return _samples.filter {
            if case let .metric(name, _, _, _) = $0 { return name.hasPrefix(prefix) }
            return false
        }.count
    }

    /// All samples whose name starts with the given prefix.
    func samples(prefix: String) -> [StatSample] {
        lock.lock(); defer { lock.unlock() }
        return _samples.filter {
            if case let .metric(name, _, _, _) = $0 { return name.hasPrefix(prefix) }
            return false
        }
    }
}

// MARK: - Schema

private let schema = SchemaDeclaration(
    kitID: "pk-telemetry-test",
    version: 1,
    tables: [
        TableDeclaration(
            name: "items",
            columns: [
                ColumnDeclaration(name: "id", type: .uuid, nullable: false),
                ColumnDeclaration(name: "payload", type: .text, nullable: false),
            ],
            primaryKey: ["id"]
        )
    ]
)

// MARK: - §1 Disabled gate

/// With monitoring OFF, reportStorageStats must not emit any samples.
/// The StorageStats result must be identical to when monitoring is on.
@Suite("§1 PersistenceKitTelemetry — disabled gate (InMemory)", .serialized)
struct PKTelemetryInMemoryDisabledTests {

    @Test("reportStorageStats does not emit when monitoring is disabled")
    func noEmitWhenDisabled() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = InMemoryStorage(configuration: EstateConfiguration(
                estateID: UUID(), backend: .inMemory
            ))
            try await storage.open(schema: schema)

            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(false)

            let now = Date(timeIntervalSince1970: 1_700_000_000)
            await reportStorageStats(storage, estateID: "test-estate", now: now)

            #expect(sink.count == 0,
                "reportStorageStats must not emit when monitoring is disabled")

            Intellectus.install(sink: NoOpSink.shared)
        }
    }

    @Test("stats() result is unchanged when monitoring is disabled")
    func statsResultUnchangedWhenDisabled() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = InMemoryStorage(configuration: EstateConfiguration(
                estateID: UUID(), backend: .inMemory
            ))
            try await storage.open(schema: schema)

            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(false)

            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let stats = await storage.stats(now: now)

            #expect(stats.capturedAt == now, "capturedAt must match the injected timestamp")
            #expect(stats.rowCount == 0, "rowCount must be 0 on empty storage")

            Intellectus.install(sink: NoOpSink.shared)
        }
    }
}

// MARK: - §2 Enabled gate

/// With monitoring ON and a capturing sink, each reportStorageStats call
/// must emit the expected metrics.
@Suite("§2 PersistenceKitTelemetry — enabled gate (InMemory)", .serialized)
struct PKTelemetryInMemoryEnabledTests {

    @Test("reportStorageStats emits at least one metric when monitoring is enabled")
    func emitsMetricsWhenEnabled() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = InMemoryStorage(configuration: EstateConfiguration(
                estateID: UUID(), backend: .inMemory
            ))
            try await storage.open(schema: schema)

            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)

            let now = Date(timeIntervalSince1970: 1_700_000_000)
            await reportStorageStats(storage, estateID: "test-estate", now: now)

            // Filter to persistence.db.* only — lower-layer kits may emit
            // other metrics when monitoring is enabled.
            let pkCount = sink.count(prefix: "persistence.db.")
            #expect(pkCount > 0,
                "reportStorageStats must emit at least one persistence.db.* metric when enabled; got \(pkCount)")

            Intellectus.setEnabled(false)
            Intellectus.install(sink: NoOpSink.shared)
        }
    }

    @Test("reportStorageStats emits size_bytes metric when enabled")
    func emitsSizeBytes() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = InMemoryStorage(configuration: EstateConfiguration(
                estateID: UUID(), backend: .inMemory
            ))
            try await storage.open(schema: schema)

            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)

            let now = Date(timeIntervalSince1970: 1_700_000_000)
            await reportStorageStats(storage, estateID: "test-estate", now: now)

            let pkSamples = sink.samples(prefix: "persistence.db.")
            let sizeMetrics = pkSamples.filter {
                if case let .metric(name, _, _, _) = $0 { return name == "persistence.db.size_bytes" }
                return false
            }
            #expect(sizeMetrics.count == 1,
                "reportStorageStats must emit exactly one persistence.db.size_bytes; got \(sizeMetrics.count)")

            Intellectus.setEnabled(false)
            Intellectus.install(sink: NoOpSink.shared)
        }
    }

    @Test("reportStorageStats emits row_count after inserts")
    func emitsRowCountAfterInserts() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = InMemoryStorage(configuration: EstateConfiguration(
                estateID: UUID(), backend: .inMemory
            ))
            try await storage.open(schema: schema)

            // Insert some rows with monitoring OFF so the row store is populated.
            Intellectus.setEnabled(false)
            for _ in 0..<3 {
                _ = try await storage.rowStore.insert(
                    table: "items",
                    values: ["id": .uuid(UUID()), "payload": .text("hello")]
                )
            }

            // Now enable monitoring and call reportStorageStats.
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)

            let now = Date(timeIntervalSince1970: 1_700_000_000)
            await reportStorageStats(storage, estateID: "test-estate", now: now)

            let pkSamples = sink.samples(prefix: "persistence.db.")
            let rowCountMetrics = pkSamples.filter {
                if case let .metric(name, _, _, _) = $0 { return name == "persistence.db.row_count" }
                return false
            }
            #expect(rowCountMetrics.count == 1,
                "must emit exactly one persistence.db.row_count; got \(rowCountMetrics.count)")

            if case let .metric(_, value, _, _) = rowCountMetrics.first! {
                #expect(value == 3.0, "row_count must equal 3 (one per insert); got \(value)")
            }

            Intellectus.setEnabled(false)
            Intellectus.install(sink: NoOpSink.shared)
        }
    }
}

// MARK: - §3 Metric shapes

/// The emitted metrics must carry the expected names, tags, and value shapes.
@Suite("§3 PersistenceKitTelemetry — metric shapes (InMemory)", .serialized)
struct PKTelemetryInMemoryShapeTests {

    @Test("size_bytes metric carries kit=PersistenceKit and estate tags")
    func sizeBytesHasCorrectTags() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = InMemoryStorage(configuration: EstateConfiguration(
                estateID: UUID(), backend: .inMemory
            ))
            try await storage.open(schema: schema)

            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)

            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let estateID = "my-test-estate"
            await reportStorageStats(storage, estateID: estateID, now: now)

            let pkSamples = sink.samples(prefix: "persistence.db.")
            let sizeMetric = pkSamples.first {
                if case let .metric(name, _, _, _) = $0 { return name == "persistence.db.size_bytes" }
                return false
            }

            guard let sm = sizeMetric,
                  case let .metric(name, value, tags, ts) = sm else {
                Issue.record("expected persistence.db.size_bytes metric")
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
                return
            }

            #expect(name == "persistence.db.size_bytes")
            #expect(value >= 0.0, "size_bytes must be non-negative; got \(value)")
            #expect(tags["kit"] == "PersistenceKit",
                "size_bytes must carry kit=PersistenceKit tag")
            #expect(tags["estate"] == estateID,
                "size_bytes must carry estate=\(estateID) tag")
            #expect(ts == now.timeIntervalSince1970,
                "ts must equal now.timeIntervalSince1970")

            Intellectus.setEnabled(false)
            Intellectus.install(sink: NoOpSink.shared)
        }
    }

    @Test("SQLite-specific metrics are absent for InMemory backend")
    func sqliteMetricsAbsentForInMemory() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = InMemoryStorage(configuration: EstateConfiguration(
                estateID: UUID(), backend: .inMemory
            ))
            try await storage.open(schema: schema)

            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)

            let now = Date(timeIntervalSince1970: 1_700_000_000)
            await reportStorageStats(storage, estateID: "test-estate", now: now)

            let pkSamples = sink.samples(prefix: "persistence.db.")
            let sqliteNames = ["persistence.db.page_size", "persistence.db.page_count",
                               "persistence.db.freelist_pages", "persistence.db.wal_frames",
                               "persistence.db.lock_contention"]
            for sqliteName in sqliteNames {
                let found = pkSamples.contains {
                    if case let .metric(name, _, _, _) = $0 { return name == sqliteName }
                    return false
                }
                #expect(!found, "\(sqliteName) must not be emitted for InMemory backend")
            }

            Intellectus.setEnabled(false)
            Intellectus.install(sink: NoOpSink.shared)
        }
    }

    @Test("blob_count metric reflects stored blobs")
    func blobCountReflectsStoredBlobs() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = InMemoryStorage(configuration: EstateConfiguration(
                estateID: UUID(), backend: .inMemory
            ))
            try await storage.open(schema: schema)

            // Add blobs with monitoring off so blob store is populated.
            Intellectus.setEnabled(false)
            try await storage.blobStore.put(key: "k1", bytes: Data("hello".utf8))
            try await storage.blobStore.put(key: "k2", bytes: Data("world".utf8))

            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)

            let now = Date(timeIntervalSince1970: 1_700_000_000)
            await reportStorageStats(storage, estateID: "test-estate", now: now)

            let pkSamples = sink.samples(prefix: "persistence.db.")
            let blobMetric = pkSamples.first {
                if case let .metric(name, _, _, _) = $0 { return name == "persistence.db.blob_count" }
                return false
            }
            guard let bm = blobMetric,
                  case let .metric(_, value, _, _) = bm else {
                Issue.record("expected persistence.db.blob_count metric")
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
                return
            }
            #expect(value == 2.0, "blob_count must equal 2; got \(value)")

            Intellectus.setEnabled(false)
            Intellectus.install(sink: NoOpSink.shared)
        }
    }
}

// MARK: - §4 Conformance gate

/// StorageStats returned by stats(now:) is identical whether or not
/// monitoring is enabled. reportStorageStats must not alter storage state.
@Suite("§4 PersistenceKitTelemetry — conformance (InMemory)", .serialized)
struct PKTelemetryInMemoryConformanceTests {

    @Test("StorageStats is identical with monitoring disabled and enabled")
    func statsIdenticalWithMonitoringOffAndOn() async throws {
        try await GlobalTestLock.shared.withLock {
            // Shared data: insert rows, blobs into both stores identically.
            let now = Date(timeIntervalSince1970: 1_700_000_000)

            // --- With monitoring OFF ---
            Intellectus.setEnabled(false)
            let storageOff = InMemoryStorage(configuration: EstateConfiguration(
                estateID: UUID(), backend: .inMemory
            ))
            try await storageOff.open(schema: schema)
            _ = try await storageOff.rowStore.insert(
                table: "items", values: ["id": .uuid(UUID()), "payload": .text("a")]
            )
            try await storageOff.blobStore.put(key: "b1", bytes: Data("data".utf8))
            await reportStorageStats(storageOff, estateID: "off-estate", now: now)
            let statsOff = await storageOff.stats(now: now)

            // --- With monitoring ON ---
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            let storageOn = InMemoryStorage(configuration: EstateConfiguration(
                estateID: UUID(), backend: .inMemory
            ))
            try await storageOn.open(schema: schema)
            _ = try await storageOn.rowStore.insert(
                table: "items", values: ["id": .uuid(UUID()), "payload": .text("a")]
            )
            try await storageOn.blobStore.put(key: "b1", bytes: Data("data".utf8))
            await reportStorageStats(storageOn, estateID: "on-estate", now: now)
            let statsOn = await storageOn.stats(now: now)

            // Stats must be structurally equivalent for the same operations.
            #expect(statsOff.rowCount == statsOn.rowCount,
                "rowCount must be equal; off=\(String(describing: statsOff.rowCount)) on=\(String(describing: statsOn.rowCount))")
            #expect(statsOff.blobCount == statsOn.blobCount,
                "blobCount must be equal")
            #expect(statsOff.capturedAt == statsOn.capturedAt,
                "capturedAt must be equal")

            // Metrics were emitted on the ON path.
            let pkCount = sink.count(prefix: "persistence.db.")
            #expect(pkCount > 0, "at least one persistence.db.* metric must be emitted when monitoring is enabled")

            Intellectus.setEnabled(false)
            Intellectus.install(sink: NoOpSink.shared)
        }
    }

    @Test("reportStorageStats does not modify the backend storage state")
    func reportDoesNotModifyStorage() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = InMemoryStorage(configuration: EstateConfiguration(
                estateID: UUID(), backend: .inMemory
            ))
            try await storage.open(schema: schema)

            // Capture stats before calling reportStorageStats.
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let before = await storage.stats(now: now)

            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            await reportStorageStats(storage, estateID: "test-estate", now: now)
            Intellectus.setEnabled(false)

            // Capture stats after — row/blob counts must be unchanged.
            let after = await storage.stats(now: now)

            #expect(before.rowCount == after.rowCount,
                "rowCount must be unchanged by reportStorageStats")
            #expect(before.blobCount == after.blobCount,
                "blobCount must be unchanged by reportStorageStats")

            Intellectus.install(sink: NoOpSink.shared)
        }
    }
}
