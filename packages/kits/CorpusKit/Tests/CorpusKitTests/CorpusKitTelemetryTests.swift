// CorpusKitTelemetryTests.swift
//
// Integration tests for the IntellectusLib telemetry emission added to
// CorpusKit in CORPUSKIT_REPORT_001 (cp-corpuskit-report).
//
// Mirrors the Rust test module in
// packages/kits/CorpusKit/rust/tests/corpuskit_telemetry_tests.rs.
//
// §1 Disabled gate: with monitoring OFF, CorpusKit operations must
//    not emit any metrics and results must be unchanged.
// §2 Enabled gate: with monitoring ON and a capturing sink, the correct
//    metrics arrive with the expected shapes after each operation.
// §3 Metric shapes: tags, names, and values conform to the
//    corpuskit.* namespace spec (CORPUSKIT_REPORT_001).
// §4 Conformance: results are byte-identical whether or not monitoring
//    is enabled — telemetry MUST NOT affect CorpusKit behaviour.
//
// CRITICAL — Global singleton isolation:
//   Intellectus is a process-wide singleton (enabled flag + installed sink).
//   Swift Testing runs suites in PARALLEL by default. Tests that toggle
//   the enabled flag or install a capturing sink will corrupt each other's
//   exact-count assertions unless they are all serialised under one lock.
//
//   Strategy: every test body that touches the Intellectus singleton OR
//   calls a CorpusKit emit method (BundleStore.insert, HybridRecall.recall)
//   acquires GlobalTestLock.shared for its entire duration. This ensures
//   at most one such body executes at a time, across ALL suites in the
//   process — including BundleStoreTests and HybridRecallTests.
//   GlobalTestLock is an actor-based async mutex (see GlobalTestLock.swift);
//   it avoids the reentrancy trap of a plain actor `run(body:)` wrapper.
//
//   The @Suite(.serialized) annotation on each telemetry suite prevents
//   concurrent execution WITHIN a suite. GlobalTestLock prevents
//   interleaving ACROSS suites and with functional tests.
//
//   Lower-layer kits (VectorKit, SubstrateKernel via EngramLib) emit their
//   own metrics when monitoring is enabled. Count assertions filter to the
//   corpuskit.* namespace to avoid counting those emissions.

import Foundation
import Testing
import EngramLib
import PersistenceKit
@testable import CorpusKit
import IntellectusLib
import VectorKit

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

// MARK: - Helper: fresh storage

/// Creates a fresh SQLite-backed storage for each test (via makeScratchStorage()).
private func makeFreshStorage() async throws -> any Storage {
    let storage = try makeScratchStorage()
    return storage
}

/// Creates a fresh BundleStore against SQLite-backed storage (via makeFreshStorage()).
private func makeFreshBundleStore() async throws -> BundleStore {
    let storage = try await makeFreshStorage()
    try await storage.migrate(to: BundleStore.schemaDeclaration)
    return BundleStore(storage: storage)
}

/// Returns a deterministic test chunk for use in tests.
private func makeTestChunk(
    sourceID: String = "source-1",
    text: String = "The quick brown fox jumps over the lazy dog."
) -> Chunk {
    Chunk(
        id: UUID(uuidString: "CAFEBABE-DEAD-BEEF-0001-000000000001")!,
        sourceID: sourceID,
        startOffset: 0,
        length: text.count,
        text: text,
        hlc: .zero,
        metadata: [:]
    )
}

// MARK: - §1 Disabled gate

/// With monitoring OFF, CorpusKit operations must not emit any
/// samples into the installed sink.
@Suite("§1 CorpusKitTelemetry — disabled gate", .serialized)
struct CorpusKitTelemetryDisabledTests {

    /// BundleStore.insert must not emit when monitoring is disabled.
    @Test("no metric emitted by BundleStore.insert when monitoring is disabled")
    func insertNoMetricWhenDisabled() async throws {
        try await GlobalTestLock.shared.withLock {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(false)

            let store = try await makeFreshBundleStore()
            try await store.insert([makeTestChunk()])

            #expect(sink.count == 0,
                "BundleStore.insert must not emit when monitoring is disabled")

            // Restore defaults.
            Intellectus.install(sink: NoOpSink.shared)
        }
    }

    /// HybridRecall.recall must not emit when monitoring is disabled.
    @Test("no metric emitted by HybridRecall.recall when monitoring is disabled")
    func recallNoMetricWhenDisabled() async throws {
        try await GlobalTestLock.shared.withLock {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(false)

            // Build fresh VectorStore + BundleStore + InvertedIndexStore for a recall call.
            let storage = try await makeFreshStorage()
            try await storage.migrate(to: BundleStore.schemaDeclaration)
            try await storage.migrate(to: VectorStore.schemaDeclaration)
            try await storage.migrate(to: InvertedIndexStore.schemaDeclaration)
            let bundleStore = BundleStore(storage: storage)
            let vectorStore = VectorStore(storage: storage)
            let invertedIndex = InvertedIndexStore(storage: storage)
            try await invertedIndex.open()

            let probe = Engram(
                blocks: 0xCAFE_BABE_DEAD_BEEF,
                        0x0123_4567_89AB_CDEF,
                        0xFFFF_0000_FFFF_0000,
                        0x0000_FFFF_0000_FFFF
            )
            _ = try await HybridRecall.recall(
                probe: probe,
                query: "test query",
                modelID: "corpus-deterministic-v1",
                limit: 5,
                vectorStore: vectorStore,
                invertedIndex: invertedIndex,
                bundleStore: bundleStore
            )

            #expect(sink.count == 0,
                "HybridRecall.recall must not emit when monitoring is disabled")

            // Restore defaults.
            Intellectus.install(sink: NoOpSink.shared)
        }
    }
}

// MARK: - §2 Enabled gate

/// With monitoring ON and a capturing sink, each CorpusKit
/// operation must emit the expected number of metrics.
@Suite("§2 CorpusKitTelemetry — enabled gate", .serialized)
struct CorpusKitTelemetryEnabledTests {

    /// BundleStore.insert must emit exactly two metrics (latency + chunk_count)
    /// when monitoring is enabled.
    @Test("BundleStore.insert emits exactly two corpuskit.* metrics when monitoring is enabled")
    func insertEmitsTwoMetrics() async throws {
        try await GlobalTestLock.shared.withLock {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)

            let store = try await makeFreshBundleStore()
            try await store.insert([makeTestChunk()])

            // Filter to corpuskit.* to exclude lower-layer emissions.
            let ckCount = sink.count(prefix: "corpuskit.")
            #expect(ckCount == 2,
                "BundleStore.insert must emit 2 corpuskit.* metrics (latency + chunk_count); got \(ckCount)")

            // Restore defaults.
            Intellectus.setEnabled(false)
            Intellectus.install(sink: NoOpSink.shared)
        }
    }

    /// HybridRecall.recall must emit exactly four corpuskit.* metrics
    /// (latency + vector_result_count + keyword_result_count + result_count)
    /// when monitoring is enabled.
    @Test("HybridRecall.recall emits exactly four corpuskit.* metrics when monitoring is enabled")
    func recallEmitsFourMetrics() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try await makeFreshStorage()
            try await storage.migrate(to: BundleStore.schemaDeclaration)
            try await storage.migrate(to: VectorStore.schemaDeclaration)
            try await storage.migrate(to: InvertedIndexStore.schemaDeclaration)
            let bundleStore = BundleStore(storage: storage)
            let vectorStore = VectorStore(storage: storage)
            let invertedIndex = InvertedIndexStore(storage: storage)
            try await invertedIndex.open()

            let probe = Engram(
                blocks: 0xCAFE_BABE_DEAD_BEEF,
                        0x0123_4567_89AB_CDEF,
                        0xFFFF_0000_FFFF_0000,
                        0x0000_FFFF_0000_FFFF
            )

            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)

            _ = try await HybridRecall.recall(
                probe: probe,
                query: "test query",
                modelID: "corpus-deterministic-v1",
                limit: 5,
                vectorStore: vectorStore,
                invertedIndex: invertedIndex,
                bundleStore: bundleStore
            )

            // Filter to corpuskit.* metrics only. Lower-layer kits
            // (VectorKit, SubstrateKernel via EngramLib) may emit their
            // own metrics into this sink when monitoring is enabled.
            let ckCount = sink.count(prefix: "corpuskit.")
            #expect(ckCount == 4,
                "HybridRecall.recall must emit 4 corpuskit.* metrics; got \(ckCount)")

            // Restore defaults.
            Intellectus.setEnabled(false)
            Intellectus.install(sink: NoOpSink.shared)
        }
    }
}

// MARK: - §3 Metric shapes

/// The emitted metrics must carry the expected names, tags, and
/// value shapes. Verifies the corpuskit.* namespace contract
/// (CORPUSKIT_REPORT_001).
@Suite("§3 CorpusKitTelemetry — metric shapes", .serialized)
struct CorpusKitTelemetryShapeTests {

    /// BundleStore.insert emits corpuskit.ingest.latency_ms with
    /// non-negative value and kit tag, plus corpuskit.ingest.chunk_count
    /// matching the input batch size.
    @Test("BundleStore.insert emits ingest metrics with correct shapes")
    func insertMetricShapes() async throws {
        try await GlobalTestLock.shared.withLock {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)

            let store = try await makeFreshBundleStore()
            // Insert a batch of 3 chunks.
            let chunks = (1...3).map { i in
                Chunk(
                    id: UUID(),
                    sourceID: "s",
                    startOffset: i * 10,
                    length: 10,
                    text: "chunk \(i)",
                    hlc: .zero,
                    metadata: [:]
                )
            }
            try await store.insert(chunks)

            // Filter to corpuskit.* metrics only.
            let ckSamples = sink.samples(prefix: "corpuskit.")
            #expect(ckSamples.count == 2,
                "insert must emit exactly 2 corpuskit.* metrics; got \(ckSamples.count)")

            // First metric: latency.
            if ckSamples.count >= 1,
               case let .metric(name, value, tags, _) = ckSamples[0] {
                #expect(name == "corpuskit.ingest.latency_ms",
                    "first metric must be corpuskit.ingest.latency_ms; got \(name)")
                #expect(value >= 0.0,
                    "latency_ms must be non-negative; got \(value)")
                #expect(tags["kit"] == "CorpusKit",
                    "ingest latency must carry kit=CorpusKit tag")
            }

            // Second metric: chunk count.
            if ckSamples.count >= 2,
               case let .metric(name, value, tags, _) = ckSamples[1] {
                #expect(name == "corpuskit.ingest.chunk_count",
                    "second metric must be corpuskit.ingest.chunk_count; got \(name)")
                #expect(value == 3.0,
                    "chunk_count must equal batch size 3; got \(value)")
                #expect(tags["kit"] == "CorpusKit",
                    "chunk_count must carry kit=CorpusKit tag")
            }

            // Restore defaults.
            Intellectus.setEnabled(false)
            Intellectus.install(sink: NoOpSink.shared)
        }
    }

    /// HybridRecall.recall emits corpuskit.recall.* metrics with
    /// correct names, tags, and value shapes.
    @Test("HybridRecall.recall emits recall metrics with correct shapes")
    func recallMetricShapes() async throws {
        try await GlobalTestLock.shared.withLock {
            // Build a corpus with one chunk + vector so that result counts
            // are predictable.
            let storage = try await makeFreshStorage()
            try await storage.migrate(to: BundleStore.schemaDeclaration)
            try await storage.migrate(to: VectorStore.schemaDeclaration)
            try await storage.migrate(to: InvertedIndexStore.schemaDeclaration)
            let bundleStore = BundleStore(storage: storage)
            let vectorStore = VectorStore(storage: storage)
            let invertedIndex = InvertedIndexStore(storage: storage)
            try await invertedIndex.open()

            // Insert one chunk and its vector with monitoring OFF so the
            // ingest metrics don't contaminate the recall assertion.
            Intellectus.setEnabled(false)
            let chunkID = UUID()
            let chunk = Chunk(
                id: chunkID,
                sourceID: "doc-1",
                startOffset: 0,
                length: 5,
                text: "hello",
                hlc: .zero,
                metadata: [:]
            )
            try await bundleStore.insert([chunk])
            try await invertedIndex.index(
                itemID: chunkID.uuidString,
                tokens: CorpusDefaultTokenizer().keywordTokens(chunk.text),
                now: Date(timeIntervalSince1970: 1_700_000_000)
            )
            let probe = Engram(
                blocks: 0xAAAA_AAAA_AAAA_AAAA,
                        0xBBBB_BBBB_BBBB_BBBB,
                        0xCCCC_CCCC_CCCC_CCCC,
                        0xDDDD_DDDD_DDDD_DDDD
            )
            try await vectorStore.addVector(
                itemID: chunkID.uuidString,
                engram: probe,
                modelID: "test-model",
                modelVersion: "1.0",
                filedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )

            // Now enable monitoring and run recall.
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)

            _ = try await HybridRecall.recall(
                probe: probe,
                query: "hello",
                modelID: "test-model",
                limit: 5,
                vectorStore: vectorStore,
                invertedIndex: invertedIndex,
                bundleStore: bundleStore
            )

            // Filter to corpuskit.* metrics only.
            let ckSamples = sink.samples(prefix: "corpuskit.")
            #expect(ckSamples.count == 4,
                "recall must emit exactly 4 corpuskit.* metrics; got \(ckSamples.count)")

            // Verify each metric by name. The order matches the emit sequence.
            let expectedNames = [
                "corpuskit.recall.latency_ms",
                "corpuskit.recall.vector_result_count",
                "corpuskit.recall.keyword_result_count",
                "corpuskit.recall.result_count",
            ]
            for (i, expected) in expectedNames.enumerated() {
                guard ckSamples.count > i,
                      case let .metric(name, value, tags, _) = ckSamples[i] else { continue }
                #expect(name == expected,
                    "metric[\(i)] must be \(expected); got \(name)")
                #expect(value >= 0.0,
                    "\(name) must be non-negative; got \(value)")
                #expect(tags["kit"] == "CorpusKit",
                    "\(name) must carry kit=CorpusKit tag")
            }

            // Restore defaults.
            Intellectus.setEnabled(false)
            Intellectus.install(sink: NoOpSink.shared)
        }
    }
}

// MARK: - §4 Conformance gate

/// CorpusKit results are byte-identical whether or not monitoring
/// is enabled. Telemetry MUST NOT alter chunk content, result ordering,
/// or counts.
@Suite("§4 CorpusKitTelemetry — conformance (results unchanged by telemetry)", .serialized)
struct CorpusKitTelemetryConformanceTests {

    /// HybridRecall.recall returns the same results with monitoring
    /// disabled vs enabled.
    ///
    /// Uses a SINGLE store populated once (with monitoring OFF), then
    /// calls recall twice on the same data — once with monitoring off
    /// and once with monitoring on. This eliminates the UUID non-
    /// determinism that would arise from building two independent stores
    /// with randomly-generated chunk IDs. Results must be identical.
    @Test("HybridRecall.recall results are identical with monitoring disabled and enabled")
    func recallResultsUnchangedByTelemetry() async throws {
        try await GlobalTestLock.shared.withLock {
            let probe = Engram(
                blocks: 0xAAAA_AAAA_AAAA_AAAA,
                        0xBBBB_BBBB_BBBB_BBBB,
                        0xCCCC_CCCC_CCCC_CCCC,
                        0xDDDD_DDDD_DDDD_DDDD
            )

            // Build one shared store with monitoring OFF.
            // All chunk IDs are deterministic (Chunk.deriveID from fixed inputs).
            Intellectus.setEnabled(false)
            let storage = try await makeFreshStorage()
            try await storage.migrate(to: BundleStore.schemaDeclaration)
            try await storage.migrate(to: VectorStore.schemaDeclaration)
            try await storage.migrate(to: InvertedIndexStore.schemaDeclaration)
            let bundleStore = BundleStore(storage: storage)
            let vectorStore = VectorStore(storage: storage)
            let invertedIndex = InvertedIndexStore(storage: storage)
            try await invertedIndex.open()

            // Fixed inputs — same IDs computed both times the test runs.
            let fixtures: [(String, String, Engram)] = [
                ("doc", "hello one",
                 Engram(blocks: 0x1111_1111_1111_1111, 0x2222_2222_2222_2222,
                               0x3333_3333_3333_3333, 0x4444_4444_4444_4444)),
                ("doc", "hello two",
                 Engram(blocks: 0x5555_5555_5555_5555, 0x6666_6666_6666_6666,
                               0x7777_7777_7777_7777, 0x8888_8888_8888_8888)),
                ("doc", "hello three",
                 Engram(blocks: 0x9999_9999_9999_9999, 0xAAAA_AAAA_AAAA_AAAA,
                               0xBBBB_BBBB_BBBB_BBBB, 0xCCCC_CCCC_CCCC_CCCC)),
            ]
            let ingestNow = Date(timeIntervalSince1970: 1_700_000_000)
            for (sourceID, text, eng) in fixtures {
                // Use content-addressed IDs so both recall calls see the same UUIDs.
                let chunkID = Chunk.deriveID(sourceID: sourceID, startOffset: 0, text: text)
                let chunk = Chunk(
                    id: chunkID,
                    sourceID: sourceID,
                    startOffset: 0,
                    length: text.count,
                    text: text,
                    hlc: .zero,
                    metadata: [:]
                )
                try await bundleStore.insert([chunk])
                try await invertedIndex.index(
                    itemID: chunkID.uuidString,
                    tokens: CorpusDefaultTokenizer().keywordTokens(text),
                    now: ingestNow
                )
                try await vectorStore.addVector(
                    itemID: chunkID.uuidString,
                    engram: eng,
                    modelID: "m",
                    modelVersion: "1",
                    filedAt: ingestNow
                )
            }

            // Run recall with monitoring OFF.
            Intellectus.setEnabled(false)
            let resultsOff = try await HybridRecall.recall(
                probe: probe,
                query: "hello",
                modelID: "m",
                limit: 5,
                vectorStore: vectorStore,
                invertedIndex: invertedIndex,
                bundleStore: bundleStore
            )

            // Run recall again with monitoring ON (capturing sink) on the
            // SAME store. Same data → same results.
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            let resultsOn = try await HybridRecall.recall(
                probe: probe,
                query: "hello",
                modelID: "m",
                limit: 5,
                vectorStore: vectorStore,
                invertedIndex: invertedIndex,
                bundleStore: bundleStore
            )

            // Results must be identical regardless of monitoring state.
            #expect(resultsOff.count == resultsOn.count,
                "recall must return same count with monitoring off and on")
            for i in 0..<resultsOff.count {
                #expect(resultsOff[i].chunk.id == resultsOn[i].chunk.id,
                    "result[\(i)].chunk.id must match; off=\(resultsOff[i].chunk.id) on=\(resultsOn[i].chunk.id)")
                #expect(resultsOff[i].score == resultsOn[i].score,
                    "result[\(i)].score must match; off=\(resultsOff[i].score) on=\(resultsOn[i].score)")
            }

            // Monitoring was on: at least some metrics were emitted.
            #expect(sink.count > 0,
                "at least one metric must be emitted when monitoring is enabled")

            // Restore defaults.
            Intellectus.setEnabled(false)
            Intellectus.install(sink: NoOpSink.shared)
        }
    }

    /// BundleStore.insert + get round-trip preserves chunk content
    /// regardless of monitoring state.
    @Test("BundleStore.insert/get round-trip is identical with monitoring disabled and enabled")
    func insertGetRoundTripUnchangedByTelemetry() async throws {
        try await GlobalTestLock.shared.withLock {
            let chunk = makeTestChunk()

            // With monitoring OFF.
            Intellectus.setEnabled(false)
            let storeOff = try await makeFreshBundleStore()
            try await storeOff.insert([chunk])
            let fetchedOff = try await storeOff.get(id: chunk.id)

            // With monitoring ON.
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            let storeOn = try await makeFreshBundleStore()
            try await storeOn.insert([chunk])
            let fetchedOn = try await storeOn.get(id: chunk.id)

            #expect(fetchedOff?.id == chunk.id,
                "get must return the exact chunk with monitoring off")
            #expect(fetchedOn?.id == chunk.id,
                "get must return the exact chunk with monitoring on")
            #expect(fetchedOff?.text == chunk.text,
                "chunk text must be preserved with monitoring off")
            #expect(fetchedOn?.text == chunk.text,
                "chunk text must be preserved with monitoring on")

            // Restore defaults.
            Intellectus.setEnabled(false)
            Intellectus.install(sink: NoOpSink.shared)
        }
    }
}
