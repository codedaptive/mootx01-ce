// DenseLaneStatusTests.swift
//
// Tests for the dense float lane (Lane D) observable degradation contract in
// the GLK RecallDirector (Step 4.5) and the FloatLaneOutcome consumption path.
//
// §1 Dark lane explainer: unionBest result carries a non-nil denseLaneStatus
//    when the dense lane is dark. All dark reasons now carry an explicit tag:
//    - No corpus: "dark:noCorpus" (previously nil — ambiguous).
//    - Corpus present, empty/nil query: "dark:emptyQuery".
//    - Corpus + query, but lane dark: "dark:noFloatRows", "dark:providerOptOut", etc.
//    - Lane ran and returned hits: nil (the ONLY nil case).
// §2 Dark lane counter: glk.recall.dense_lane_dark counter moves when lane is
//    dark in a unionBest recall.
// §3 Hit path: denseLaneStatus is nil when the lane ran and produced hits.
// §4 Other modes: locusOnly, corpusOnly (degraded), hybrid carry nil
//    denseLaneStatus (these modes do not attempt the dense float lane).
// §5 Counter not emitted when monitoring is disabled.
// §6 storeError force-proof: full chain assert via _testForceFloatStoreError seam.
//
// INTELLECTUS LOCK: all tests that toggle Intellectus or call GLK methods that
// cross telemetry emit sites (open, recall) hold withIntellectusLock for their
// entire duration.

import Testing
import Foundation
import LocusKit
import CorpusKit
@testable import CorpusKit
import VectorKit
import PersistenceKit
import PersistenceKitInMemory
import IntellectusLib
@testable import GeniusLocusKit

// MARK: - Helpers

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

/// Open a fresh in-memory GLK estate. No corpus or vector store registered.
private func openBareEstate() async throws -> (GeniusLocusKit, EstateHandle) {
    let kit = GeniusLocusKit()
    let owner = OwnerCredentials(ownerIdentifier: "dense-lane-test-owner")
    let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
    let storage = InMemoryStorage(configuration: config)
    _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
    let handle = try await kit.open(storage: storage, owner: owner)
    return (kit, handle)
}

/// Open an estate and register a deterministic Corpus with no ingested content.
/// The deterministic provider supports embedFloat (returns 32 floats), but the
/// float row store is empty → floatNearest returns .unavailableNoFloatRows.
private func openEstateWithDeterministicCorpusNoIngest() async throws
    -> (kit: GeniusLocusKit, handle: EstateHandle) {
    let kit = GeniusLocusKit()
    let owner = OwnerCredentials(ownerIdentifier: "dense-lane-noingest-owner")
    let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
    let storage = InMemoryStorage(configuration: config)
    _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
    let handle = try await kit.open(storage: storage, owner: owner)

    let corpusStorage = InMemoryStorage(configuration: EstateConfiguration(
        estateID: UUID(), backend: .inMemory))
    let corpus = try await CorpusKit.Corpus(storage: corpusStorage, model: .deterministic)
    await kit.registerCorpus(corpus, for: handle)

    return (kit: kit, handle: handle)
}

/// Open an estate, capture a drawer, register a float-capable corpus with
/// an ingested document. This is the happy path where the dense lane fires.
private func openEstateWithFloatCorpusAndIngest() async throws
    -> (kit: GeniusLocusKit, handle: EstateHandle, drawer: LocusKit.Drawer) {
    let kit = GeniusLocusKit()
    let owner = OwnerCredentials(ownerIdentifier: "dense-lane-float-owner")
    let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
    let storage = InMemoryStorage(configuration: config)
    _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
    let handle = try await kit.open(storage: storage, owner: owner)

    let frame = CaptureFrame(
        content: "dense float lane test content for embedding recall",
        channel: .typed,
        room: "dense-lane-tests",
        latticeAnchor: .udc("000.000"),
        addedBy: "dense-lane-tests",
        embeddingModelID: "test-model-v1"
    )
    let drawer = try await kit.capture(handle, frame)

    let corpusStorage = InMemoryStorage(configuration: EstateConfiguration(
        estateID: UUID(), backend: .inMemory))
    let corpus = try await CorpusKit.Corpus(
        storage: corpusStorage,
        model: .miniLM(inference: { tokens in
            let v = Float((tokens.first ?? 0) % 4 + 1) / 4.0
            return Array(repeating: v, count: 384)
        })
    )
    try await corpus.ingest(frame.content, sourceID: drawer.id, now: t0)
    await kit.registerCorpus(corpus, for: handle)

    return (kit: kit, handle: handle, drawer: drawer)
}

/// Recall frame that matches every active row in the test estate.
private func recallAllActive() -> RecallFrame {
    RecallFrame(
        filterChain: [.unconfirmed],
        hydrationLevel: .structured,
        ordering: .byCaptureTimeDesc
    )
}

private final class CapturingSink: StatsSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _samples: [StatSample] = []

    func receive(_ sample: StatSample) {
        lock.lock()
        _samples.append(sample)
        lock.unlock()
    }

    func count(name: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return _samples.filter {
            if case let .metric(n, _, _, _) = $0 { return n == name }
            return false
        }.count
    }
}

// MARK: - §1 Dark lane explainer

@Suite("§1 DenseLaneStatus — explainer marker in GLKRecallResult", .serialized)
struct DenseLaneExplainerTests {

    /// unionBest with no corpus registered: dense lane was never attempted →
    /// denseLaneStatus must carry "dark:noCorpus" so callers can distinguish
    /// "lane never attempted" from "lane ran and returned hits" (nil).
    @Test("denseLaneStatus is dark:noCorpus when no corpus is registered")
    func denseLaneStatusDarkNoCorpusWhenNoCorpus() async throws {
        let (kit, handle) = try await openBareEstate()
        let request = GLKRecallRequest(
            frame: recallAllActive(),
            mode: .unionBest,
            scoring: .rrf,
            limit: 5,
            queryText: "dense float lane test",
            origin: .internal
        )
        let result = try await kit.recall(handle, request)
        #expect(result.denseLaneStatus == "dark:noCorpus",
            "denseLaneStatus must be 'dark:noCorpus' when no corpus is registered; got '\(result.denseLaneStatus ?? "nil")'")
    }

    /// unionBest with no corpus + empty query → denseLaneStatus must be
    /// "dark:noCorpus" (the no-corpus check fires first; same outer guard).
    @Test("denseLaneStatus is dark:noCorpus when no corpus and empty query text")
    func denseLaneStatusDarkNoCorpusEmptyQuery() async throws {
        let (kit, handle) = try await openBareEstate()
        let request = GLKRecallRequest(
            frame: recallAllActive(),
            mode: .unionBest,
            scoring: .rrf,
            limit: 5,
            queryText: "",   // empty query
            origin: .internal
        )
        let result = try await kit.recall(handle, request)
        #expect(result.denseLaneStatus == "dark:noCorpus",
            "denseLaneStatus must be 'dark:noCorpus' when no corpus (no-corpus check fires first); got '\(result.denseLaneStatus ?? "nil")'")
    }

    /// unionBest with corpus registered but query text nil → denseLaneStatus
    /// must be "dark:emptyQuery" so callers can distinguish "lane never
    /// attempted due to missing query" from "lane ran and returned hits".
    @Test("denseLaneStatus is dark:emptyQuery when corpus registered and query text is nil")
    func denseLaneStatusDarkEmptyQueryWhenQueryTextNil() async throws {
        let (kit, handle) = try await openEstateWithDeterministicCorpusNoIngest()
        let request = GLKRecallRequest(
            frame: recallAllActive(),
            mode: .unionBest,
            scoring: .rrf,
            limit: 5,
            queryText: nil,  // no query text
            origin: .internal
        )
        let result = try await kit.recall(handle, request)
        #expect(result.denseLaneStatus == "dark:emptyQuery",
            "denseLaneStatus must be 'dark:emptyQuery' when corpus registered but no query; got '\(result.denseLaneStatus ?? "nil")'")
    }

    /// unionBest with a deterministic corpus + no ingest: corpus is registered, the
    /// lane is attempted, embedFloat succeeds but no float rows exist →
    /// denseLaneStatus must carry "dark:noFloatRows".
    @Test("denseLaneStatus is dark:noFloatRows when corpus registered but no float rows")
    func denseLaneStatusDarkNoFloatRowsWhenEmptyCorpus() async throws {
        let (kit, handle) = try await openEstateWithDeterministicCorpusNoIngest()
        let request = GLKRecallRequest(
            frame: recallAllActive(),
            mode: .unionBest,
            scoring: .rrf,
            limit: 5,
            queryText: "dense float lane test",
            origin: .internal
        )
        let result = try await kit.recall(handle, request)

        // The deterministic provider embeds the query to 32 floats but the store
        // has no ingested documents → .unavailableNoFloatRows → "dark:noFloatRows".
        #expect(result.denseLaneStatus == "dark:noFloatRows",
            "denseLaneStatus must be 'dark:noFloatRows' for empty corpus; got '\(result.denseLaneStatus ?? "nil")'")
    }
}

// MARK: - §2 Dark lane counter

@Suite("§2 DenseLaneStatus — glk.recall.dense_lane_dark counter", .serialized)
struct DenseLaneCounterTests {

    /// glk.recall.dense_lane_dark must be emitted when the lane is dark in a
    /// unionBest recall with monitoring enabled.
    @Test("dense_lane_dark counter moves when lane is dark in unionBest")
    func denseLaneDarkCounterMovesWhenDark() async throws {
        try await withIntellectusLock {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }

            let (kit, handle) = try await openEstateWithDeterministicCorpusNoIngest()
            let request = GLKRecallRequest(
                frame: recallAllActive(),
                mode: .unionBest,
                scoring: .rrf,
                limit: 5,
                queryText: "dense float lane test",
                origin: .internal
            )
            _ = try await kit.recall(handle, request)

            let darkCount = sink.count(name: "glk.recall.dense_lane_dark")
            #expect(darkCount >= 1,
                "glk.recall.dense_lane_dark must be emitted at least once; got \(darkCount)")

            // corpus.float_lane.dark_no_rows must also have been emitted by CorpusKit.
            let ckDarkRows = sink.count(name: "corpus.float_lane.dark_no_rows")
            #expect(ckDarkRows >= 1,
                "corpus.float_lane.dark_no_rows must be emitted by CorpusKit; got \(ckDarkRows)")
        }
    }

    /// When monitoring is disabled, dense_lane_dark must NOT be emitted.
    @Test("dense_lane_dark counter not emitted when monitoring is disabled")
    func denseLaneDarkCounterNotEmittedWhenMonitoringOff() async throws {
        try await withIntellectusLock {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(false)
            defer {
                Intellectus.install(sink: NoOpSink.shared)
            }

            let (kit, handle) = try await openEstateWithDeterministicCorpusNoIngest()
            let request = GLKRecallRequest(
                frame: recallAllActive(),
                mode: .unionBest,
                scoring: .rrf,
                limit: 5,
                queryText: "test",
                origin: .internal
            )
            _ = try await kit.recall(handle, request)

            let darkCount = sink.count(name: "glk.recall.dense_lane_dark")
            #expect(darkCount == 0,
                "dense_lane_dark must not be emitted when monitoring is disabled; got \(darkCount)")
        }
    }
}

// MARK: - §3 Happy path (hits)

@Suite("§3 DenseLaneStatus — happy path", .serialized)
struct DenseLaneHappyPathTests {

    /// With a float-capable corpus and ingested content, denseLaneStatus must be
    /// nil (the lane ran and contributed hits → no dark marker).
    @Test("denseLaneStatus is nil when dense lane ran and produced hits")
    func denseLaneStatusNilOnHits() async throws {
        let (kit, handle, _) = try await openEstateWithFloatCorpusAndIngest()
        let request = GLKRecallRequest(
            frame: recallAllActive(),
            mode: .unionBest,
            scoring: .rrf,
            limit: 5,
            queryText: "dense float lane test content",
            origin: .internal
        )
        let result = try await kit.recall(handle, request)

        // Dense lane ran and produced hits → no dark marker.
        #expect(result.denseLaneStatus == nil,
            "denseLaneStatus must be nil when dense lane produced hits; got '\(result.denseLaneStatus ?? "nil")'")
    }
}

// MARK: - §4 Other modes carry nil denseLaneStatus

@Suite("§4 DenseLaneStatus — non-unionBest modes carry nil", .serialized)
struct DenseLaneOtherModesTests {

    /// locusOnly does not attempt the dense float lane → denseLaneStatus == nil.
    @Test("locusOnly result carries nil denseLaneStatus")
    func locusOnlyCarriesNilDenseLaneStatus() async throws {
        let (kit, handle) = try await openBareEstate()
        let request = GLKRecallRequest(
            frame: recallAllActive(),
            mode: .locusOnly,
            scoring: .rrf,
            limit: 5,
            origin: .internal
        )
        let result = try await kit.recall(handle, request)
        #expect(result.denseLaneStatus == nil,
            "locusOnly denseLaneStatus must be nil; got '\(result.denseLaneStatus ?? "nil")'")
    }

    /// hybrid does not include the dense float lane → denseLaneStatus == nil.
    @Test("hybrid result carries nil denseLaneStatus")
    func hybridCarriesNilDenseLaneStatus() async throws {
        let (kit, handle) = try await openBareEstate()
        let request = GLKRecallRequest(
            frame: recallAllActive(),
            mode: .hybrid,
            scoring: .rrf,
            limit: 5,
            fallback: .allowDegraded,
            queryText: "some query text",
            origin: .internal
        )
        let result = try await kit.recall(handle, request)
        #expect(result.denseLaneStatus == nil,
            "hybrid denseLaneStatus must be nil; got '\(result.denseLaneStatus ?? "nil")'")
    }

    /// corpusOnly (degraded to locusOnly) does not include the dense float lane.
    @Test("corpusOnly degrades to locusOnly (allowDegraded) and carries nil denseLaneStatus")
    func corpusOnlyDegradedCarriesNilDenseLaneStatus() async throws {
        let (kit, handle) = try await openBareEstate()
        let request = GLKRecallRequest(
            frame: recallAllActive(),
            mode: .corpusOnly,
            scoring: .rrf,
            limit: 5,
            fallback: .allowDegraded,
            queryText: "some query text",
            origin: .internal
        )
        let result = try await kit.recall(handle, request)
        #expect(result.denseLaneStatus == nil,
            "corpusOnly (degraded to locusOnly) denseLaneStatus must be nil; got '\(result.denseLaneStatus ?? "nil")'")
    }
}

// MARK: - §6 storeError force-proof

/// Full-chain proof for the storeError path.
///
/// Uses the `_testForceFloatStoreError(_:)` seam (internal API, accessible via
/// `@testable import CorpusKit`) to force the storeError outcome on the next
/// `floatNearest` call. Asserts the complete chain:
///  1. `denseLaneStatus == "dark:storeError"`
///  2. The query survives — hits are present from locus/BM25/Hamming lanes.
///  3. No fake `.vectorDense` evidence appears on any hit.
@Suite("§6 DenseLaneStatus — storeError force-proof", .serialized)
struct DenseLaneStoreErrorTests {

    /// Captures a drawer, registers a float-capable corpus, ingests the content,
    /// then forces a storeError on the next floatNearest call and runs UnionBest recall.
    @Test("storeError: denseLaneStatus dark:storeError, query survives, no fake vectorDense evidence")
    func storeErrorFullChain() async throws {
        try await withIntellectusLock {
            // Capturing sink: the chain sentence is status + COUNTER + no fake
            // evidence — the counter assertion is part of the contract, not an
            // optional extra (gate-2 round-2 scoring).
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }

            let kit = GeniusLocusKit()
            let owner = OwnerCredentials(ownerIdentifier: "dense-lane-store-error-owner")
            let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
            let storage = InMemoryStorage(configuration: config)
            _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
            let handle = try await kit.open(storage: storage, owner: owner)

            // Capture a drawer so locus/BM25/Hamming lanes have content to return.
            let frame = CaptureFrame(
                content: "store error chain test content photosynthesis recall",
                channel: .typed,
                room: "store-error-tests",
                latticeAnchor: .udc("000.000"),
                addedBy: "store-error-tests",
                embeddingModelID: "test-model-v1"
            )
            let drawer = try await kit.capture(handle, frame)

            // Build a corpus using the miniLM path (supports embedFloat).
            let corpusStorage = InMemoryStorage(configuration: EstateConfiguration(
                estateID: UUID(), backend: .inMemory))
            let corpus = try await CorpusKit.Corpus(
                storage: corpusStorage,
                model: .miniLM(inference: { tokens in
                    let v = Float((tokens.first ?? 0) % 4 + 1) / 4.0
                    return Array(repeating: v, count: 384)
                })
            )
            try await corpus.ingest(frame.content, sourceID: drawer.id, now: t0)
            await kit.registerCorpus(corpus, for: handle)

            // Force the store error on the NEXT floatNearest call (single-use seam).
            await corpus._testForceFloatStoreError(
                CorpusKitError.storeUnavailable("forced-store-error-for-glk-chain-test")
            )

            let request = GLKRecallRequest(
                frame: RecallFrame(
                    filterChain: [.unconfirmed],
                    hydrationLevel: .structured,
                    ordering: .byCaptureTimeDesc
                ),
                mode: .unionBest,
                scoring: .rrf,
                limit: 5,
                queryText: "photosynthesis recall store error chain",
                origin: .internal
            )
            let result = try await kit.recall(handle, request)

            // [1] denseLaneStatus carries the expected dark reason.
            #expect(result.denseLaneStatus == "dark:storeError",
                "forced storeError must produce dark:storeError; got '\(result.denseLaneStatus ?? "nil")'")

            // [2] Query survived — at least one hit from other lanes.
            #expect(!result.hits.isEmpty,
                "query must survive storeError and return hits from locus/BM25/Hamming lanes")

            // [3] No fake .vectorDense evidence on any hit.
            for hit in result.hits {
                #expect(!hit.sources.contains(.vectorDense),
                    "hit \(hit.id) must NOT carry vectorDense evidence after storeError; sources: \(hit.sources)")
                #expect(hit.score.dense == 0.0,
                    "hit \(hit.id) dense score must be 0.0 after storeError; got \(hit.score.dense)")
            }

            // [4] COUNTERS — the dark counter at GLK and the store-error counter
            // at CorpusKit both emit (status + counter + no fake evidence).
            #expect(sink.count(name: "glk.recall.dense_lane_dark") >= 1,
                "glk.recall.dense_lane_dark must emit on storeError")
            #expect(sink.count(name: "corpus.float_lane.store_error") >= 1,
                "corpus.float_lane.store_error must emit on forced store error")
        }
    }
}
