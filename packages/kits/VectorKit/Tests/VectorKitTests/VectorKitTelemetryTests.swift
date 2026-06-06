// VectorKitTelemetryTests.swift
//
// Integration tests for the IntellectusLib telemetry emission added to
// VectorStore in VECTORKIT_REPORT_001.
//
// Mirrors the Rust test module in
// packages/kits/VectorKit/rust/tests/vectorkit_telemetry_tests.rs.
//
// §1 Disabled gate: with monitoring OFF, VectorStore operations must
//    not emit any metrics and results must be unchanged.
// §2 Enabled gate: with monitoring ON and a capturing sink, the correct
//    metrics arrive with the expected shapes after each operation.
// §3 Metric shapes: tags, names, and values conform to the
//    vectorkit.* namespace spec (VECTORKIT_REPORT_001).
// §4 Conformance: results are byte-identical whether or not monitoring
//    is enabled — telemetry MUST NOT affect VectorStore behavior.
//
// CRITICAL — Global singleton isolation:
//   Intellectus is a process-wide singleton (enabled flag + installed sink).
//   Swift Testing runs suites in PARALLEL by default. Tests that toggle
//   the enabled flag or install a capturing sink will corrupt each other's
//   exact-count assertions unless they are all serialized under one lock.
//
//   Strategy: every test body that touches the Intellectus singleton OR
//   calls a VectorStore emit method (addVector, findNearest, findByKeyword)
//   acquires GlobalTestLock.shared for its entire duration. This ensures
//   at most one such body executes at a time, across ALL suites in the
//   process — including VectorStoreTests. GlobalTestLock is an actor-based
//   async mutex (see GlobalTestLock.swift); it avoids the reentrancy trap
//   of a plain actor `run(body:)` wrapper.
//
//   The @Suite(.serialized) annotation on each telemetry suite prevents
//   concurrent execution WITHIN a suite. GlobalTestLock prevents
//   interleaving ACROSS suites and with VectorStoreTests.
//
//   Lower-layer kits (SubstrateKernel via EngramLib) emit their own
//   metrics (e.g. substrate.kernel.backend_selected) when monitoring is
//   enabled. Count assertions filter to the vectorkit.* namespace to
//   avoid counting those emissions.

import Foundation
import Testing
import EngramLib
import PersistenceKit
import PersistenceKitInMemory
@testable import VectorKit
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

    var samples: [StatSample] {
        lock.lock(); defer { lock.unlock() }
        return _samples
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

// MARK: - Helper: fresh store

/// Creates a fresh InMemory-backed VectorStore for each test.
private func makeFreshStore() async throws -> VectorStore {
    let storage = InMemoryStorage(configuration: EstateConfiguration(
        estateID: UUID(),
        backend: .inMemory
    ))
    try await storage.open(schema: VectorStore.schemaDeclaration)
    return VectorStore(storage: storage)
}

/// A fixed deterministic Engram for tests.
private let testEngram = Engram(
    blocks: 0xCAFE_BABE_DEAD_BEEF,
            0x0123_4567_89AB_CDEF,
            0xFFFF_0000_FFFF_0000,
            0x0000_FFFF_0000_FFFF
)

// MARK: - §1 Disabled gate

/// With monitoring OFF, VectorStore operations must not emit any
/// samples into the installed sink. Results must be identical to
/// those produced with monitoring enabled (§4 conformance).
@Suite("§1 VectorKitTelemetry — disabled gate", .serialized)
struct VectorKitTelemetryDisabledTests {

    /// addVector must not emit when monitoring is disabled.
    @Test("no metric emitted by addVector when monitoring is disabled")
    func addVectorNoMetricWhenDisabled() async throws {
        try await GlobalTestLock.shared.withLock {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(false)

            let store = try await makeFreshStore()
            try await store.addVector(
                drawerID: "d1",
                engram: testEngram,
                modelID: "minilm",
                modelVersion: "1.0",
                filedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )

            #expect(sink.count == 0,
                "addVector must not emit when monitoring is disabled")

            // Restore defaults.
            Intellectus.install(sink: NoOpSink.shared)
        }
    }

    /// findNearest must not emit when monitoring is disabled.
    @Test("no metric emitted by findNearest when monitoring is disabled")
    func findNearestNoMetricWhenDisabled() async throws {
        try await GlobalTestLock.shared.withLock {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(false)

            let store = try await makeFreshStore()
            try await store.addVector(
                drawerID: "d1",
                engram: testEngram,
                modelID: "minilm",
                modelVersion: "1.0",
                filedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            _ = try await store.findNearest(probe: testEngram, modelID: "minilm", limit: 5)

            #expect(sink.count == 0,
                "findNearest must not emit when monitoring is disabled")

            // Restore defaults.
            Intellectus.install(sink: NoOpSink.shared)
        }
    }

    /// findByKeyword must not emit when monitoring is disabled.
    @Test("no metric emitted by findByKeyword when monitoring is disabled")
    func findByKeywordNoMetricWhenDisabled() async throws {
        try await GlobalTestLock.shared.withLock {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(false)

            let store = try await makeFreshStore()
            _ = try await store.findByKeyword("drawer", limit: 10)

            #expect(sink.count == 0,
                "findByKeyword must not emit when monitoring is disabled")

            // Restore defaults.
            Intellectus.install(sink: NoOpSink.shared)
        }
    }
}

// MARK: - §2 Enabled gate

/// With monitoring ON and a capturing sink, each VectorStore
/// operation must emit the expected number of metrics.
@Suite("§2 VectorKitTelemetry — enabled gate", .serialized)
struct VectorKitTelemetryEnabledTests {

    /// addVector must emit exactly one metric when monitoring is enabled.
    @Test("addVector emits exactly one metric when monitoring is enabled")
    func addVectorEmitsOneMetric() async throws {
        try await GlobalTestLock.shared.withLock {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)

            let store = try await makeFreshStore()
            try await store.addVector(
                drawerID: "d1",
                engram: testEngram,
                modelID: "minilm",
                modelVersion: "1.0",
                filedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )

            // Only assert on vectorkit.* emissions; lower-layer kits may
            // emit substrate.* metrics via the same enabled sink.
            #expect(sink.count(prefix: "vectorkit.") == 1,
                "addVector must emit exactly one vectorkit.* metric; got \(sink.count(prefix: "vectorkit."))")

            // Restore defaults.
            Intellectus.setEnabled(false)
            Intellectus.install(sink: NoOpSink.shared)
        }
    }

    /// findNearest must emit exactly two metrics (latency + result count)
    /// when monitoring is enabled.
    @Test("findNearest emits exactly two metrics when monitoring is enabled")
    func findNearestEmitsTwoMetrics() async throws {
        try await GlobalTestLock.shared.withLock {
            let store = try await makeFreshStore()

            // Insert with monitoring off so addVector does not contaminate
            // the findNearest count assertion.
            Intellectus.setEnabled(false)
            try await store.addVector(
                drawerID: "d1",
                engram: testEngram,
                modelID: "minilm",
                modelVersion: "1.0",
                filedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )

            // Now enable monitoring and run the search.
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)

            _ = try await store.findNearest(probe: testEngram, modelID: "minilm", limit: 5)

            // Count only vectorkit.* metrics. Lower-layer kits (e.g.
            // SubstrateKernel via EngramLib) may emit their own metrics
            // into this sink when monitoring is enabled.
            let vkCount = sink.count(prefix: "vectorkit.")
            #expect(vkCount == 2,
                "findNearest must emit 2 vectorkit.* metrics (latency + result_count); got \(vkCount)")

            // Restore defaults.
            Intellectus.setEnabled(false)
            Intellectus.install(sink: NoOpSink.shared)
        }
    }

    /// findByKeyword must emit exactly one metric when monitoring is enabled.
    @Test("findByKeyword emits exactly one metric when monitoring is enabled")
    func findByKeywordEmitsOneMetric() async throws {
        try await GlobalTestLock.shared.withLock {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)

            let store = try await makeFreshStore()
            _ = try await store.findByKeyword("drawer", limit: 10)

            #expect(sink.count(prefix: "vectorkit.") == 1,
                "findByKeyword must emit exactly one vectorkit.* metric; got \(sink.count(prefix: "vectorkit."))")

            // Restore defaults.
            Intellectus.setEnabled(false)
            Intellectus.install(sink: NoOpSink.shared)
        }
    }
}

// MARK: - §3 Metric shapes

/// The emitted metrics must carry the expected names, tags, and
/// value shapes. Verifies the vectorkit.* namespace contract
/// (VECTORKIT_REPORT_001).
@Suite("§3 VectorKitTelemetry — metric shapes", .serialized)
struct VectorKitTelemetryShapeTests {

    /// addVector emits vectorkit.index.insert_latency_ms with positive
    /// value and kit + model_id tags.
    @Test("addVector emits insert_latency_ms with correct shape")
    func addVectorLatencyMetricShape() async throws {
        try await GlobalTestLock.shared.withLock {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)

            let store = try await makeFreshStore()
            try await store.addVector(
                drawerID: "d1",
                engram: testEngram,
                modelID: "minilm",
                modelVersion: "1.0",
                filedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )

            // Filter to vectorkit.* to exclude any substrate.* emissions.
            let vkSamples = sink.samples(prefix: "vectorkit.")
            guard let sample = vkSamples.first,
                  case let .metric(name, value, tags, _) = sample else {
                Issue.record("expected a vectorkit.* .metric sample; got \(String(describing: sink.samples.first))")
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
                return
            }

            #expect(name == "vectorkit.index.insert_latency_ms",
                "insert latency metric must be named vectorkit.index.insert_latency_ms")
            #expect(value >= 0.0,
                "latency_ms must be non-negative; got \(value)")
            #expect(tags["kit"] == "VectorKit",
                "insert latency must carry kit=VectorKit tag")
            #expect(tags["model_id"] == "minilm",
                "insert latency must carry model_id=minilm tag")

            // Restore defaults.
            Intellectus.setEnabled(false)
            Intellectus.install(sink: NoOpSink.shared)
        }
    }

    /// findNearest emits vectorkit.search.latency_ms and
    /// vectorkit.search.result_count with correct shapes.
    @Test("findNearest emits search latency and result count with correct shapes")
    func findNearestMetricShapes() async throws {
        try await GlobalTestLock.shared.withLock {
            // Populate store with monitoring off to avoid contaminating sink.
            let store = try await makeFreshStore()
            Intellectus.setEnabled(false)
            try await store.addVector(
                drawerID: "d1",
                engram: testEngram,
                modelID: "minilm",
                modelVersion: "1.0",
                filedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )

            // Now enable monitoring and run the search.
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)

            _ = try await store.findNearest(probe: testEngram, modelID: "minilm", limit: 5)

            // Filter to vectorkit.* metrics only. Lower-layer kits (e.g.
            // SubstrateKernel via EngramLib) may emit their own metrics
            // into this sink; we assert only on the VectorKit namespace.
            let vkSamples = sink.samples(prefix: "vectorkit.")
            #expect(vkSamples.count == 2,
                "findNearest must emit exactly 2 vectorkit.* metrics; got \(vkSamples.count)")

            // First VectorKit metric: latency.
            if vkSamples.count >= 1,
               case let .metric(name, value, tags, _) = vkSamples[0] {
                #expect(name == "vectorkit.search.latency_ms",
                    "first vectorkit.* metric must be vectorkit.search.latency_ms")
                #expect(value >= 0.0, "latency_ms must be non-negative")
                #expect(tags["kit"] == "VectorKit")
                #expect(tags["model_id"] == "minilm")
            }

            // Second VectorKit metric: result count.
            if vkSamples.count >= 2,
               case let .metric(name, value, tags, _) = vkSamples[1] {
                #expect(name == "vectorkit.search.result_count",
                    "second vectorkit.* metric must be vectorkit.search.result_count")
                // One vector was inserted for "minilm"; findNearest returns 1.
                #expect(value == 1.0,
                    "result_count must equal number of matches returned; got \(value)")
                #expect(tags["kit"] == "VectorKit")
                #expect(tags["model_id"] == "minilm")
            }

            // Restore defaults.
            Intellectus.setEnabled(false)
            Intellectus.install(sink: NoOpSink.shared)
        }
    }

    /// findByKeyword emits vectorkit.search.keyword_result_count with
    /// the correct count.
    @Test("findByKeyword emits keyword_result_count with correct shape")
    func findByKeywordMetricShape() async throws {
        try await GlobalTestLock.shared.withLock {
            // Populate store with monitoring off.
            let store = try await makeFreshStore()
            Intellectus.setEnabled(false)
            for i in 1...3 {
                try await store.addVector(
                    drawerID: "drawer-\(i)",
                    engram: testEngram,
                    modelID: "minilm",
                    modelVersion: "1.0",
                    filedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i))
                )
            }

            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)

            _ = try await store.findByKeyword("drawer", limit: 10)

            let vkSamples = sink.samples(prefix: "vectorkit.")
            guard let sample = vkSamples.first,
                  case let .metric(name, value, tags, _) = sample else {
                Issue.record("expected a vectorkit.* .metric sample; got nothing")
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
                return
            }

            #expect(name == "vectorkit.search.keyword_result_count",
                "keyword metric must be named vectorkit.search.keyword_result_count")
            #expect(value == 3.0,
                "keyword_result_count must equal 3 (one per distinct drawer); got \(value)")
            #expect(tags["kit"] == "VectorKit")

            // Restore defaults.
            Intellectus.setEnabled(false)
            Intellectus.install(sink: NoOpSink.shared)
        }
    }
}

// MARK: - §4 Conformance gate

/// VectorStore results are byte-identical whether or not monitoring
/// is enabled. Telemetry MUST NOT alter vector math, engram bytes,
/// result ordering, or counts.
@Suite("§4 VectorKitTelemetry — conformance (results unchanged by telemetry)", .serialized)
struct VectorKitTelemetryConformanceTests {

    /// findNearest returns the same ordered results with monitoring
    /// disabled vs enabled.
    @Test("findNearest results are identical with monitoring disabled and enabled")
    func findNearestResultsUnchangedByTelemetry() async throws {
        try await GlobalTestLock.shared.withLock {
            let probe = Engram(
                blocks: 0xAAAA_AAAA_AAAA_AAAA,
                        0xBBBB_BBBB_BBBB_BBBB,
                        0xCCCC_CCCC_CCCC_CCCC,
                        0xDDDD_DDDD_DDDD_DDDD
            )
            let engrams: [(String, Engram)] = [
                ("d1", Engram(blocks: 0xAAAA_AAAA_AAAA_AAAA, 0xBBBB_BBBB_BBBB_BBBB,
                              0xCCCC_CCCC_CCCC_CCCC, 0xDDDD_DDDD_DDDD_DDDD)),
                ("d2", Engram(blocks: 0xFFFF_FFFF_FFFF_FFFF, 0x0000_0000_0000_0000,
                              0xFFFF_FFFF_FFFF_FFFF, 0x0000_0000_0000_0000)),
                ("d3", Engram(blocks: 0x1234_5678_9ABC_DEF0, 0xFEDC_BA98_7654_3210,
                              0x0F0F_0F0F_0F0F_0F0F, 0xF0F0_F0F0_F0F0_F0F0)),
            ]
            let now = Date(timeIntervalSince1970: 1_700_000_000)

            // --- Run with monitoring OFF ---
            Intellectus.setEnabled(false)
            let storeOff = try await makeFreshStore()
            for (id, eng) in engrams {
                try await storeOff.addVector(drawerID: id, engram: eng,
                                             modelID: "m", modelVersion: "1",
                                             filedAt: now)
            }
            let resultsOff = try await storeOff.findNearest(probe: probe, modelID: "m", limit: 3)

            // --- Run with monitoring ON (capturing sink) ---
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            let storeOn = try await makeFreshStore()
            for (id, eng) in engrams {
                try await storeOn.addVector(drawerID: id, engram: eng,
                                            modelID: "m", modelVersion: "1",
                                            filedAt: now)
            }
            let resultsOn = try await storeOn.findNearest(probe: probe, modelID: "m", limit: 3)

            // Results must be identical regardless of monitoring state.
            #expect(resultsOff.count == resultsOn.count,
                "findNearest must return same count with monitoring off and on")
            for i in 0..<resultsOff.count {
                #expect(resultsOff[i].drawerID == resultsOn[i].drawerID,
                    "result[\(i)].drawerID must match; off=\(resultsOff[i].drawerID) on=\(resultsOn[i].drawerID)")
                #expect(resultsOff[i].distance == resultsOn[i].distance,
                    "result[\(i)].distance must match; off=\(resultsOff[i].distance) on=\(resultsOn[i].distance)")
            }

            // Monitoring was on: at least some metrics were emitted.
            #expect(sink.count > 0, "at least one metric must be emitted when monitoring is enabled")

            // Restore defaults.
            Intellectus.setEnabled(false)
            Intellectus.install(sink: NoOpSink.shared)
        }
    }

    /// addVector + getVector round-trip preserves the engram exactly,
    /// regardless of monitoring state.
    @Test("addVector/getVector round-trip is byte-identical with monitoring disabled and enabled")
    func addVectorGetVectorRoundTripUnchangedByTelemetry() async throws {
        try await GlobalTestLock.shared.withLock {
            let now = Date(timeIntervalSince1970: 1_700_000_000)

            // With monitoring OFF.
            Intellectus.setEnabled(false)
            let storeOff = try await makeFreshStore()
            try await storeOff.addVector(drawerID: "d1", engram: testEngram,
                                         modelID: "m", modelVersion: "1",
                                         filedAt: now)
            let fetchedOff = try await storeOff.getVector(drawerID: "d1", modelID: "m")

            // With monitoring ON.
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            let storeOn = try await makeFreshStore()
            try await storeOn.addVector(drawerID: "d1", engram: testEngram,
                                        modelID: "m", modelVersion: "1",
                                        filedAt: now)
            let fetchedOn = try await storeOn.getVector(drawerID: "d1", modelID: "m")

            #expect(fetchedOff == testEngram,
                "getVector must return the exact engram with monitoring off")
            #expect(fetchedOn == testEngram,
                "getVector must return the exact engram with monitoring on")

            // Restore defaults.
            Intellectus.setEnabled(false)
            Intellectus.install(sink: NoOpSink.shared)
        }
    }
}
