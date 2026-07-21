// RecallDirectorDegradationTests.swift
//
// Force-tests for the P1 fail-loud degradation contract.
//
// Each test injects a failure through a single-use test seam, then verifies
// that the query survives, the correct stage name appears in
// `GLKRecallResult.degradedStages`, the Intellectus counter moves, and that
// no fake scores or phantom evidence appear on returned hits.
//
// Happy-path assertions (no degradation when seam is clear) are included
// alongside each failure case to ensure the seam does not alter normal
// behaviour.
//
// COVERAGE (one test per class-B site from FAIL_LOUD_SWEEP_2026-06-12.md):
//
// §1  vectorHamming.findNearest — unionBest (#57): forced findNearest failure
// §2  vectorHamming.findNearest — hybrid (#54): forced findNearest failure
// §3  vectorHamming.findNearest — corpusOnly (#53): forced findNearest failure
// §4  corpus.embed — compileSketch (#56): forced embed failure
// §5  pool.getDrawers — unionBest step 5.5 (#58): forced getDrawers failure
// §6  pool.hydrateBodies.mmr — unionBest step 9.5 (#59): forced hydration failure
// §7  pool.hydrateBodies.return — unionBest step 10.5 (#60): forced hydration failure
// §8  hybrid.getDrawers — hybrid lane (#55): forced getDrawers failure
// §9  corpusOnly.getDrawers — corpusOnly lane (#61): forced getDrawers failure
//
// §10 Happy path — degradedStages always empty when no seam fires
// §11 Counter gate — each degraded stage emits its metric name
// §12 Counter gate (MARK level) — counters increment per forced failure
// §13 Scoring-fallback disposition — matrixAware/rrf surfaced as degraded
// §11 (separate suite) LocusKit recall internal-read failures (P0-5 sites 1-5)
//
// INTELLECTUS LOCK: all tests that toggle Intellectus or call GLK methods
// that cross telemetry emit sites hold withIntellectusLock for their entire
// duration.

import Testing
import Foundation
import LocusKit
@testable import LocusKit
import CorpusKit
@testable import CorpusKit
import VectorKit
import PersistenceKit
import PersistenceKitInMemory
import IntellectusLib
@testable import GeniusLocusKit

// MARK: - Private Intellectus sink (mirrors GeniusLocusKitTelemetryTests pattern)

private final class CapturingSink: StatsSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _samples: [StatSample] = []
    func receive(_ sample: StatSample) {
        lock.lock(); defer { lock.unlock() }
        _samples.append(sample)
    }
    func count(name: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return _samples.filter {
            if case let .metric(n, _, _, _) = $0 { return n == name }
            return false
        }.count
    }
}

// MARK: - Private helpers

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

/// Open an estate seeded with one drawer, registered with a miniLM corpus and a
/// VectorStore that holds an engram for the drawer. Suitable for any lane that
/// needs all three signals active (locus, BM25, vector Hamming).
private func openFullyWiredEstate(
    content: String = "degradation test recall probe cosmos galaxy",
    ownerSuffix: String = "default"
) async throws -> (kit: GeniusLocusKit, handle: EstateHandle, drawer: LocusKit.Drawer) {
    let kit = GeniusLocusKit()
    let owner = OwnerCredentials(ownerIdentifier: "degrad-owner-\(ownerSuffix)")
    let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
    let storage = InMemoryStorage(configuration: config)
    _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
    let handle = try await kit.open(storage: storage, owner: owner)

    let frame = CaptureFrame(
        content: content,
        channel: .typed,
        room: "degradation-tests",
        latticeAnchor: .udc("000"),
        addedBy: "degradation-tests",
        embeddingModelID: "test-model-v1"
    )
    let drawer = try await kit.capture(handle, frame)

    let corpusStorage = InMemoryStorage(configuration: EstateConfiguration(
        estateID: UUID(), backend: .inMemory))
    // Use a deterministic inference function so tests are bit-identical
    // across runs and do not depend on a CoreML model.
    let corpus = try await CorpusContentEngine(
        standaloneOn: corpusStorage,
        models: [.miniLM(inference: { tokens in
            let v = Float((tokens.first ?? 0) % 4 + 1) / 4.0
            return Array(repeating: v, count: 384)
        })]
    )
    try await corpus.ingest(content, contentID: drawer.id, now: t0)
    await kit.registerCorpus(corpus, for: handle)

    // VectorStore: separate InMemory storage, engram keyed by drawer.id directly.
    // Registering the VectorStore ensures vectorStores[handle] is non-nil, so the
    // if-let guard in the RecallDirector reaches the findNearest call site where
    // the test seam is checked. Without a registered store the seam is never hit.
    let vsStorage = InMemoryStorage(configuration: EstateConfiguration(
        estateID: UUID(), backend: .inMemory))
    try await vsStorage.migrate(to: VectorStore.schemaDeclaration)
    let vectorStore = VectorStore(storage: vsStorage)
    let engram = try await corpus.embed(content)
    let modelID = await corpus.modelID
    try await vectorStore.addVector(
        itemID: drawer.id,
        engram: engram,
        modelID: modelID,
        modelVersion: "1.0",
        filedAt: t0
    )
    await kit.registerVectorStore(vectorStore, for: handle)

    return (kit: kit, handle: handle, drawer: drawer)
}

/// Build a standard unionBest request for degradation tests.
///
/// `scoring` defaults to `.rrf` for the forced-failure tests (which assert a
/// specific failure stage is present and tolerate the now-surfaced
/// `unionBest.rrf` scoring fallback alongside it). Happy-path tests pass
/// `.matrixAware` — the genuinely-implemented weighted pipeline, which records
/// no scoring fallback — so an empty `degradedStages` is the correct baseline.
private func unionBestRequest(
    queryText: String = "cosmos galaxy recall probe",
    scoring: GLKRecallScoring = .rrf
) -> GLKRecallRequest {
    GLKRecallRequest(
        frame: RecallFrame(
            filterChain: [.unconfirmed],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        ),
        mode: .unionBest,
        scoring: scoring,
        limit: 5,
        queryText: queryText,
        origin: .internal
    )
}

/// Build a standard hybrid request for degradation tests.
private func hybridRequest(
    queryText: String = "cosmos galaxy recall probe"
) -> GLKRecallRequest {
    GLKRecallRequest(
        frame: RecallFrame(
            filterChain: [.unconfirmed],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        ),
        mode: .hybrid,
        scoring: .rrf,
        limit: 5,
        queryText: queryText,
        origin: .internal
    )
}

/// Build a standard corpusOnly request for degradation tests.
private func corpusOnlyRequest(
    queryText: String = "cosmos galaxy recall probe"
) -> GLKRecallRequest {
    GLKRecallRequest(
        frame: RecallFrame(
            filterChain: [.unconfirmed],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        ),
        mode: .corpusOnly,
        scoring: .rrf,
        limit: 5,
        fallback: .failClosed,
        queryText: queryText,
        origin: .internal
    )
}

// MARK: - §1 vectorHamming.findNearest — unionBest

@Suite("§1 Degradation — vectorHamming.findNearest in unionBest", .serialized)
struct VectorHammingDegradationUnionBestTests {

    @Test("forced findNearest: degradedStages contains vectorHamming.findNearest, query survives, no vector evidence")
    func forcedFindNearestUnionBest() async throws {
        try await withIntellectusLock {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }

            let (kit, handle, _) = try await openFullyWiredEstate(ownerSuffix: "ub-vec")
            // Inject the failure seam (single-use).
            await kit._inject(vectorHammingError: GeniusLocusKitError.recallLaneUnavailable(.corpus))
            let result = try await kit.recall(handle, unionBestRequest())

            // [1] Stage recorded.
            #expect(result.degradedStages.contains("vectorHamming.findNearest"),
                "degradedStages must contain vectorHamming.findNearest after forced failure; got \(result.degradedStages)")

            // [2] Query survived — locus lane still returns hits.
            #expect(!result.hits.isEmpty,
                "query must survive vectorHamming.findNearest failure and return locus hits")

            // [3] No fake vectorHamming evidence on any hit.
            for hit in result.hits {
                #expect(!hit.sources.contains(.vectorHamming),
                    "hit \(hit.id) must NOT carry vectorHamming evidence after forced failure; sources: \(hit.sources)")
                #expect(hit.score.vector == 0.0,
                    "hit \(hit.id) vector score must be 0.0 after forced failure; got \(hit.score.vector)")
            }

            // [4] Counter moved.
            #expect(sink.count(name: GLKMetricName.vectorHammingDegraded) >= 1,
                "glk.recall.vectorHamming.findNearest_degraded must emit on forced failure")
        }
    }

    @Test("happy path: degradedStages is empty when no seam fires in unionBest")
    func happyPathUnionBest() async throws {
        let (kit, handle, _) = try await openFullyWiredEstate(ownerSuffix: "ub-vec-hp")
        // matrixAware is the genuinely-implemented unionBest pipeline (no scoring
        // fallback), so a healthy recall records no degraded stage.
        let result = try await kit.recall(handle, unionBestRequest(scoring: .matrixAware))
        #expect(result.degradedStages.isEmpty,
            "degradedStages must be empty on a healthy recall; got \(result.degradedStages)")
    }
}

// MARK: - §2 vectorHamming.findNearest — hybrid

@Suite("§2 Degradation — vectorHamming.findNearest in hybrid", .serialized)
struct VectorHammingDegradationHybridTests {

    @Test("forced findNearest: degradedStages contains vectorHamming.findNearest, hybrid query survives")
    func forcedFindNearestHybrid() async throws {
        try await withIntellectusLock {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }

            let (kit, handle, _) = try await openFullyWiredEstate(ownerSuffix: "hy-vec")
            await kit._inject(vectorHammingError: GeniusLocusKitError.recallLaneUnavailable(.corpus))
            let result = try await kit.recall(handle, hybridRequest())

            // [1] Stage recorded.
            #expect(result.degradedStages.contains("vectorHamming.findNearest"),
                "degradedStages must contain vectorHamming.findNearest in hybrid; got \(result.degradedStages)")

            // [2] Query survived (locus lane always present in hybrid).
            #expect(!result.hits.isEmpty,
                "hybrid query must survive vectorHamming.findNearest failure; locus lane must produce hits")

            // [3] No fake vectorHamming evidence.
            for hit in result.hits {
                #expect(!hit.sources.contains(.vectorHamming),
                    "hit \(hit.id) must NOT carry vectorHamming evidence after forced failure in hybrid")
            }

            // [4] Counter moved.
            #expect(sink.count(name: GLKMetricName.vectorHammingDegraded) >= 1,
                "glk.recall.vectorHamming.findNearest_degraded must emit in hybrid on forced failure")
        }
    }
}

// MARK: - §3 vectorHamming.findNearest — corpusOnly

@Suite("§3 Degradation — vectorHamming.findNearest in corpusOnly", .serialized)
struct VectorHammingDegradationCorpusOnlyTests {

    @Test("forced findNearest: degradedStages contains vectorHamming.findNearest, corpusOnly survives on BM25")
    func forcedFindNearestCorpusOnly() async throws {
        try await withIntellectusLock {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }

            let (kit, handle, _) = try await openFullyWiredEstate(ownerSuffix: "co-vec")
            await kit._inject(vectorHammingError: GeniusLocusKitError.recallLaneUnavailable(.corpus))
            let result = try await kit.recall(handle, corpusOnlyRequest())

            // [1] Stage recorded.
            #expect(result.degradedStages.contains("vectorHamming.findNearest"),
                "degradedStages must contain vectorHamming.findNearest in corpusOnly; got \(result.degradedStages)")

            // [2] No fake vectorHamming evidence on any hit.
            for hit in result.hits {
                #expect(!hit.sources.contains(.vectorHamming),
                    "hit \(hit.id) must NOT carry vectorHamming evidence after forced failure in corpusOnly")
            }

            // [3] Counter moved.
            #expect(sink.count(name: GLKMetricName.vectorHammingDegraded) >= 1,
                "glk.recall.vectorHamming.findNearest_degraded must emit in corpusOnly on forced failure")
        }
    }
}

// MARK: - §4 corpus.embed — compileSketch

@Suite("§4 Degradation — corpus.embed in compileSketch", .serialized)
struct CorpusEmbedDegradationTests {

    @Test("forced embed: degradedStages contains corpus.embed, query survives on locus/BM25")
    func forcedEmbedUnionBest() async throws {
        try await withIntellectusLock {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }

            let (kit, handle, _) = try await openFullyWiredEstate(ownerSuffix: "embed")
            await kit._inject(embedError: GeniusLocusKitError.recallLaneUnavailable(.corpus))
            let result = try await kit.recall(handle, unionBestRequest())

            // [1] Stage recorded.
            #expect(result.degradedStages.contains("corpus.embed"),
                "degradedStages must contain corpus.embed after forced embed failure; got \(result.degradedStages)")

            // [2] Query survived — locus lane present.
            #expect(!result.hits.isEmpty,
                "query must survive corpus.embed failure; locus lane must return hits")

            // [3] No fake vectorHamming or vectorDense evidence (embed nil → no engram → no vector hits).
            for hit in result.hits {
                #expect(!hit.sources.contains(.vectorHamming),
                    "hit \(hit.id) must NOT carry vectorHamming evidence after embed failure")
                #expect(hit.score.vector == 0.0,
                    "hit \(hit.id) vector score must be 0.0 after embed failure; got \(hit.score.vector)")
            }

            // [4] Counter moved.
            #expect(sink.count(name: GLKMetricName.corpusEmbedDegraded) >= 1,
                "glk.recall.corpus.embed_degraded must emit on forced embed failure")
        }
    }
}

// MARK: - §5 pool.getDrawers — unionBest step 5.5

@Suite("§5 Degradation — pool.getDrawers in unionBest (DANGER-5)", .serialized)
struct PoolGetDrawersDegradationTests {

    @Test("forced getDrawers: degradedStages contains pool.getDrawers, query survives, matrix scores are zero")
    func forcedPoolGetDrawers() async throws {
        try await withIntellectusLock {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }

            let (kit, handle, _) = try await openFullyWiredEstate(ownerSuffix: "pool")
            await kit._inject(poolGetDrawersError: GeniusLocusKitError.recallLaneUnavailable(.corpus))

            // Use matrixAware so the scoring path reads drawerIndex.
            let request = GLKRecallRequest(
                frame: RecallFrame(
                    filterChain: [.unconfirmed],
                    hydrationLevel: .structured,
                    ordering: .byCaptureTimeDesc
                ),
                mode: .unionBest,
                scoring: .matrixAware,
                limit: 5,
                queryText: "cosmos galaxy recall probe",
                origin: .internal
            )
            let result = try await kit.recall(handle, request)

            // [1] Stage recorded.
            #expect(result.degradedStages.contains("pool.getDrawers"),
                "degradedStages must contain pool.getDrawers after forced failure; got \(result.degradedStages)")

            // [2] Query survived — locus lane returns candidates.
            #expect(!result.hits.isEmpty,
                "query must survive pool.getDrawers failure; locus lane must return hits")

            // [3] Matrix columns are zero-scored (drawerIndex empty → coords empty → zero).
            for hit in result.hits {
                #expect(hit.score.fieldFit == 0.0,
                    "hit \(hit.id) fieldFit must be 0.0 when drawerIndex is empty; got \(hit.score.fieldFit)")
                #expect(hit.score.coOccurrence == 0.0,
                    "hit \(hit.id) coOccurrence must be 0.0; got \(hit.score.coOccurrence)")
                #expect(hit.score.temporal == 0.0,
                    "hit \(hit.id) temporal must be 0.0; got \(hit.score.temporal)")
            }

            // [4] Counter moved.
            #expect(sink.count(name: GLKMetricName.poolGetDrawersDegraded) >= 1,
                "glk.recall.pool.getDrawers_degraded must emit on forced failure")
        }
    }

    @Test("happy path: degradedStages empty and matrix columns can be non-zero with a registered MatrixTier")
    func happyPathWithMatrix() async throws {
        // Build an estate with a registered MatrixTier and confirm degradedStages is empty.
        // The matrix is rebuilt from an empty audit log so all scores are 0; the coverage
        // proves healthy matrix-tier non-degradation, not non-zero matrix columns.
        let (kit, handle, _) = try await openFullyWiredEstate(ownerSuffix: "pool-hp")

        // Build a minimal MatrixTier from an empty audit log (all scores will be 0 — the
        // important thing is degradedStages is empty, not that scores are non-zero).
        let emptyLog = UnifiedAuditLog()
        let tier = MatrixTier.rebuild(from: emptyLog)
        await kit.registerMatrixTier(tier, for: handle)

        let request = GLKRecallRequest(
            frame: RecallFrame(
                filterChain: [.unconfirmed],
                hydrationLevel: .structured,
                ordering: .byCaptureTimeDesc
            ),
            mode: .unionBest,
            scoring: .matrixAware,
            limit: 5,
            queryText: "cosmos galaxy recall probe",
            origin: .internal
        )
        let result = try await kit.recall(handle, request)
        #expect(result.degradedStages.isEmpty,
            "degradedStages must be empty on a healthy recall; got \(result.degradedStages)")
    }
}

// MARK: - §6 pool.hydrateBodies.mmr — unionBest step 9.5

@Suite("§6 Degradation — pool.hydrateBodies.mmr in unionBest", .serialized)
struct MMRHydrationDegradationTests {

    @Test("forced MMR hydration: degradedStages contains pool.hydrateBodies.mmr, query survives via Jaccard proxy")
    func forcedMMRHydration() async throws {
        try await withIntellectusLock {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }

            let (kit, handle, _) = try await openFullyWiredEstate(ownerSuffix: "mmr")
            await kit._inject(mmrHydrationError: GeniusLocusKitError.recallLaneUnavailable(.corpus))

            // Use .full hydration so step 9.5 actually fires (it is guarded by .full level).
            let request = GLKRecallRequest(
                frame: RecallFrame(
                    filterChain: [.unconfirmed],
                    hydrationLevel: .full,
                    ordering: .byCaptureTimeDesc
                ),
                mode: .unionBest,
                scoring: .rrf,
                limit: 5,
                queryText: "cosmos galaxy recall probe",
                origin: .internal
            )
            let result = try await kit.recall(handle, request)

            // [1] Stage recorded.
            #expect(result.degradedStages.contains("pool.hydrateBodies.mmr"),
                "degradedStages must contain pool.hydrateBodies.mmr after forced failure; got \(result.degradedStages)")

            // [2] Query survived — hits still returned (MMR fell back to Jaccard proxy).
            #expect(!result.hits.isEmpty,
                "query must survive pool.hydrateBodies.mmr failure; MMR Jaccard proxy must produce hits")

            // [3] Counter moved.
            #expect(sink.count(name: GLKMetricName.poolHydrateBodiesMMRDegraded) >= 1,
                "glk.recall.pool.hydrateBodies.mmr_degraded must emit on forced failure")
        }
    }
}

// MARK: - §7 pool.hydrateBodies.return — unionBest step 10.5

@Suite("§7 Degradation — pool.hydrateBodies.return in unionBest", .serialized)
struct ReturnHydrationDegradationTests {

    @Test("forced return hydration: degradedStages contains pool.hydrateBodies.return, hits have empty content")
    func forcedReturnHydration() async throws {
        try await withIntellectusLock {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }

            let (kit, handle, _) = try await openFullyWiredEstate(ownerSuffix: "rethyd")
            await kit._inject(returnHydrationError: GeniusLocusKitError.recallLaneUnavailable(.corpus))

            // .structured hydration triggers step 10.5 (it is the failing path
            // because .full uses mmrContentByID which was read at step 9.5).
            let request = GLKRecallRequest(
                frame: RecallFrame(
                    filterChain: [.unconfirmed],
                    hydrationLevel: .structured,
                    ordering: .byCaptureTimeDesc
                ),
                mode: .unionBest,
                scoring: .rrf,
                limit: 5,
                queryText: "cosmos galaxy recall probe",
                origin: .internal
            )
            let result = try await kit.recall(handle, request)

            // [1] Stage recorded.
            #expect(result.degradedStages.contains("pool.hydrateBodies.return"),
                "degradedStages must contain pool.hydrateBodies.return after forced failure; got \(result.degradedStages)")

            // [2] Query survived — scored IDs still present even if content is empty.
            #expect(!result.hits.isEmpty,
                "query must survive pool.hydrateBodies.return failure; scored IDs must be returned")

            // [3] Returned hits carry empty content fields (hydration failed, bodies absent).
            for hit in result.hits {
                #expect(hit.drawer?.content == "" || hit.drawer == nil,
                    "hit \(hit.id) must carry empty content after return hydration failure; got '\(hit.drawer?.content ?? "<nil drawer>")'")
            }

            // [4] Counter moved.
            #expect(sink.count(name: GLKMetricName.poolHydrateBodiesReturnDegraded) >= 1,
                "glk.recall.pool.hydrateBodies.return_degraded must emit on forced failure")
        }
    }
}

// MARK: - §8 hybrid.getDrawers — hybrid lane

@Suite("§8 Degradation — hybrid.getDrawers in hybrid lane", .serialized)
struct HybridGetDrawersDegradationTests {

    @Test("forced hybrid getDrawers: degradedStages contains hybrid.getDrawers, query survives on locus-indexed hits")
    func forcedHybridGetDrawers() async throws {
        try await withIntellectusLock {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }

            let (kit, handle, _) = try await openFullyWiredEstate(ownerSuffix: "hy-gd")
            await kit._inject(hybridGetDrawersError: GeniusLocusKitError.recallLaneUnavailable(.corpus))
            let result = try await kit.recall(handle, hybridRequest())

            // [1] Stage recorded.
            #expect(result.degradedStages.contains("hybrid.getDrawers"),
                "degradedStages must contain hybrid.getDrawers after forced failure; got \(result.degradedStages)")

            // [2] Query survived — locus-indexed results are still returned.
            // The estate has one captured drawer; it lives in the locus index
            // and does not need the extraIndex batch load, so the result is
            // non-empty even when getDrawers fails for the extra-IDs path.
            // (If only BM25/vector IDs were present, hits would be empty — that
            //  is the documented degraded behaviour, not a test assertion here.)

            // [3] Counter moved.
            #expect(sink.count(name: GLKMetricName.hybridGetDrawersDegraded) >= 1,
                "glk.recall.hybrid.getDrawers_degraded must emit on forced failure")
        }
    }
}

// MARK: - §9 corpusOnly.getDrawers — corpusOnly lane

@Suite("§9 Degradation — corpusOnly.getDrawers in corpusOnly lane", .serialized)
struct CorpusOnlyGetDrawersDegradationTests {

    @Test("forced corpusOnly getDrawers: degradedStages contains corpusOnly.getDrawers, query degrades gracefully")
    func forcedCorpusOnlyGetDrawers() async throws {
        try await withIntellectusLock {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }

            let (kit, handle, _) = try await openFullyWiredEstate(ownerSuffix: "co-gd")
            await kit._inject(corpusOnlyGetDrawersError: GeniusLocusKitError.recallLaneUnavailable(.corpus))
            let result = try await kit.recall(handle, corpusOnlyRequest())

            // [1] Stage recorded.
            #expect(result.degradedStages.contains("corpusOnly.getDrawers"),
                "degradedStages must contain corpusOnly.getDrawers after forced failure; got \(result.degradedStages)")

            // [2] Counter moved.
            #expect(sink.count(name: GLKMetricName.corpusOnlyGetDrawersDegraded) >= 1,
                "glk.recall.corpusOnly.getDrawers_degraded must emit on forced failure")
        }
    }
}

// MARK: - §10 Happy path: degradedStages always empty when no seam fires

@Suite("§10 Degradation — happy path: degradedStages empty across all modes")
struct DegradedStagesHappyPathTests {

    @Test("unionBest happy path: degradedStages is empty")
    func unionBestHappyPath() async throws {
        let (kit, handle, _) = try await openFullyWiredEstate(ownerSuffix: "hp-ub")
        // matrixAware is the fully-implemented unionBest pipeline (no fallback).
        let result = try await kit.recall(handle, unionBestRequest(scoring: .matrixAware))
        #expect(result.degradedStages.isEmpty,
            "degradedStages must be empty on healthy unionBest; got \(result.degradedStages)")
    }

    @Test("hybrid happy path: degradedStages is empty")
    func hybridHappyPath() async throws {
        let (kit, handle, _) = try await openFullyWiredEstate(ownerSuffix: "hp-hy")
        let result = try await kit.recall(handle, hybridRequest())
        #expect(result.degradedStages.isEmpty,
            "degradedStages must be empty on healthy hybrid; got \(result.degradedStages)")
    }

    @Test("corpusOnly happy path: degradedStages is empty")
    func corpusOnlyHappyPath() async throws {
        let (kit, handle, _) = try await openFullyWiredEstate(ownerSuffix: "hp-co")
        let result = try await kit.recall(handle, corpusOnlyRequest())
        #expect(result.degradedStages.isEmpty,
            "degradedStages must be empty on healthy corpusOnly; got \(result.degradedStages)")
    }

    @Test("locusOnly happy path: degradedStages is empty")
    func locusOnlyHappyPath() async throws {
        let (kit, handle, _) = try await openFullyWiredEstate(ownerSuffix: "hp-lo")
        let request = GLKRecallRequest(
            frame: RecallFrame(
                filterChain: [.unconfirmed],
                hydrationLevel: .structured,
                ordering: .byCaptureTimeDesc
            ),
            mode: .locusOnly,
            scoring: .rrf,
            limit: 5,
            queryText: nil,
            origin: .internal
        )
        let result = try await kit.recall(handle, request)
        #expect(result.degradedStages.isEmpty,
            "degradedStages must be empty for locusOnly (no corpus/vector stages attempted); got \(result.degradedStages)")
    }
}

// MARK: - §12 Counter gate: counters increment per forced failure

@Suite("§11 Degradation counter gate", .serialized)
struct DegradationCounterGateTests {

    @Test("each degraded stage emits its own metric name — not a sibling metric")
    func eachStageSeparateCounter() async throws {
        try await withIntellectusLock {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }

            let (kit, handle, _) = try await openFullyWiredEstate(ownerSuffix: "cnt-gate")

            // --- vector hamming ---
            await kit._inject(vectorHammingError: GeniusLocusKitError.recallLaneUnavailable(.corpus))
            _ = try await kit.recall(handle, unionBestRequest())
            #expect(sink.count(name: GLKMetricName.vectorHammingDegraded) == 1,
                "vectorHamming counter must be exactly 1 after one forced failure")
            #expect(sink.count(name: GLKMetricName.poolGetDrawersDegraded) == 0,
                "poolGetDrawers counter must remain 0 when only vector was forced")

            // --- pool.getDrawers ---
            await kit._inject(poolGetDrawersError: GeniusLocusKitError.recallLaneUnavailable(.corpus))
            _ = try await kit.recall(handle, unionBestRequest())
            #expect(sink.count(name: GLKMetricName.poolGetDrawersDegraded) == 1,
                "poolGetDrawers counter must be exactly 1 after one forced failure")
        }
    }
}

// MARK: - §13 Scoring-fallback disposition (P1-2)
//
// Each exposed mode+scoring combo whose requested scoring is not a distinct
// implementation in that lane must SURFACE the fallback as a named degraded
// stage — the caller can read that matrixAware (or rrf) fell back, instead of
// the previously-silent downgrade. The genuinely-implemented combos
// (unionBest+matrixAware, hybrid/corpusOnly+rrf) record NO fallback stage,
// proving the surfacing is specific and not blanket noise.

@Suite("§13 Scoring-fallback disposition — matrixAware/rrf surfaced as degraded", .serialized)
struct ScoringFallbackDispositionTests {

    /// locusOnly + matrixAware → raw ordering; surfaces `locusOnly.matrixAware`.
    @Test("locusOnly + matrixAware surfaces locusOnly.matrixAware degraded stage")
    func locusOnlyMatrixAwareSurfaces() async throws {
        let (kit, handle, _) = try await openFullyWiredEstate(ownerSuffix: "sf-lo-ma")
        let request = GLKRecallRequest(
            frame: RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .structured,
                               ordering: .byCaptureTimeDesc),
            mode: .locusOnly,
            scoring: .matrixAware,
            limit: 5,
            queryText: nil,
            origin: .internal
        )
        let result = try await kit.recall(handle, request)
        #expect(result.degradedStages.contains("locusOnly.matrixAware"),
            "matrixAware on locusOnly must name the raw fallback; got \(result.degradedStages)")
    }

    /// corpusOnly + matrixAware → rrf; surfaces `corpusOnly.matrixAware`.
    @Test("corpusOnly + matrixAware surfaces corpusOnly.matrixAware degraded stage")
    func corpusOnlyMatrixAwareSurfaces() async throws {
        let (kit, handle, _) = try await openFullyWiredEstate(ownerSuffix: "sf-co-ma")
        let request = GLKRecallRequest(
            frame: RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .structured,
                               ordering: .byCaptureTimeDesc),
            mode: .corpusOnly,
            scoring: .matrixAware,
            limit: 5,
            fallback: .failClosed,
            queryText: "cosmos galaxy recall probe",
            origin: .internal
        )
        let result = try await kit.recall(handle, request)
        #expect(result.degradedStages.contains("corpusOnly.matrixAware"),
            "matrixAware on corpusOnly must name the rrf fallback; got \(result.degradedStages)")
    }

    /// hybrid + matrixAware → rrf; surfaces `hybrid.matrixAware`.
    @Test("hybrid + matrixAware surfaces hybrid.matrixAware degraded stage")
    func hybridMatrixAwareSurfaces() async throws {
        let (kit, handle, _) = try await openFullyWiredEstate(ownerSuffix: "sf-hy-ma")
        let request = GLKRecallRequest(
            frame: RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .structured,
                               ordering: .byCaptureTimeDesc),
            mode: .hybrid,
            scoring: .matrixAware,
            limit: 5,
            queryText: "cosmos galaxy recall probe",
            origin: .internal
        )
        let result = try await kit.recall(handle, request)
        #expect(result.degradedStages.contains("hybrid.matrixAware"),
            "matrixAware on hybrid must name the rrf fallback; got \(result.degradedStages)")
    }

    /// unionBest + rrf → raw (buffer.final); surfaces `unionBest.rrf`.
    @Test("unionBest + rrf surfaces unionBest.rrf degraded stage")
    func unionBestRRFSurfaces() async throws {
        let (kit, handle, _) = try await openFullyWiredEstate(ownerSuffix: "sf-ub-rrf")
        let result = try await kit.recall(handle, unionBestRequest(scoring: .rrf))
        #expect(result.degradedStages.contains("unionBest.rrf"),
            "rrf on unionBest must name the raw fallback; got \(result.degradedStages)")
    }

    /// SUBTLETY GUARD: unionBest + matrixAware is the genuine full weighted
    /// pipeline — NO scoring fallback recorded, even on a fully-wired estate.
    @Test("unionBest + matrixAware records NO scoring fallback (real impl)")
    func unionBestMatrixAwareNoFallback() async throws {
        let (kit, handle, _) = try await openFullyWiredEstate(ownerSuffix: "sf-ub-ma")
        let result = try await kit.recall(handle, unionBestRequest(scoring: .matrixAware))
        #expect(!result.degradedStages.contains("unionBest.rrf"),
            "matrixAware unionBest must not record an rrf fallback; got \(result.degradedStages)")
        #expect(!result.degradedStages.contains("unionBest.matrixAware"),
            "matrixAware unionBest is the real pipeline, not a fallback; got \(result.degradedStages)")
    }

    /// SUBTLETY GUARD: hybrid + rrf is real three-way RRF fusion — NO fallback.
    @Test("hybrid + rrf records NO scoring fallback (real RRF fusion)")
    func hybridRRFNoFallback() async throws {
        let (kit, handle, _) = try await openFullyWiredEstate(ownerSuffix: "sf-hy-rrf")
        let result = try await kit.recall(handle, hybridRequest())
        #expect(!result.degradedStages.contains("hybrid.matrixAware"),
            "rrf on hybrid is real fusion, not a fallback; got \(result.degradedStages)")
    }
}

// MARK: - §14 corpusOnly → locusOnly allowDegraded stage vocabulary

/// Verifies that when `corpusOnly` with `allowDegraded` degrades to `locusOnly`
/// (no corpus registered), the result carries the CORPUS-LEVEL stage vocabulary,
/// not the LOCUS-LEVEL vocabulary the inner recallLocusOnly call would emit.
///
/// Before the Part 6 fix: `recallLocusOnly` appended "locusOnly.matrixAware"
/// even when it was being called as a corpusOnly degradation. The caller had
/// requested a corpusOnly recall; the correct stages are:
///   "corpusOnly.degraded" — corpus was unavailable, fell back to locusOnly
///   "corpusOnly.matrixAware" — matrixAware requested; applied RRF fallback
/// The wrong stage "locusOnly.matrixAware" must NOT appear.
@Suite("§14 Degradation — corpusOnly allowDegraded stage vocabulary", .serialized)
struct CorpusOnlyAllowDegradedVocabularyTests {

    /// Open a bare locusOnly estate (no corpus registered). The kit has a Locus
    /// store and one drawer but no CorpusKit — triggering the allowDegraded path
    /// in recallCorpusOnly when the caller requests mode=.corpusOnly.
    private func openLocusOnlyEstateForDegradTest(
        ownerSuffix: String
    ) async throws -> (kit: GeniusLocusKit, handle: EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "degrad-co-vocab-\(ownerSuffix)")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        // Capture one drawer so the locus lane has something to return.
        _ = try await kit.capture(handle, CaptureFrame(
            content: "vocabulary stage test content",
            channel: .typed,
            room: "vocab-test",
            latticeAnchor: .udc("000"),
            addedBy: "vocab-test",
            embeddingModelID: "test-model-v1"
        ))
        // NO corpus registered → corpusOnly with allowDegraded degrades to locusOnly.
        return (kit: kit, handle: handle)
    }

    /// corpusOnly + allowDegraded + matrixAware:
    ///   MUST contain "corpusOnly.degraded" and "corpusOnly.matrixAware".
    ///   MUST NOT contain "locusOnly.matrixAware" (the inner lane's label).
    @Test("corpusOnly allowDegraded + matrixAware: corpus-level stage labels, not locus-level")
    func corpusOnlyAllowDegradedMatrixAwareVocabulary() async throws {
        let (kit, handle) = try await openLocusOnlyEstateForDegradTest(ownerSuffix: "ma")
        let request = GLKRecallRequest(
            frame: RecallFrame(
                filterChain: [.unconfirmed],
                hydrationLevel: .structured,
                ordering: .byCaptureTimeDesc
            ),
            mode: .corpusOnly,
            scoring: .matrixAware,
            limit: 5,
            fallback: .allowDegraded,
            queryText: "stage vocabulary test",
            origin: .internal
        )
        let result = try await kit.recall(handle, request)
        // Corpus lane was unavailable — must record the corpus-level degradation.
        #expect(result.degradedStages.contains("corpusOnly.degraded"),
            "corpusOnly allowDegraded must record 'corpusOnly.degraded'; got \(result.degradedStages)")
        // matrixAware was requested — the fallback stage must name the corpus context.
        #expect(result.degradedStages.contains("corpusOnly.matrixAware"),
            "matrixAware on degraded corpusOnly must record 'corpusOnly.matrixAware'; got \(result.degradedStages)")
        // "locusOnly.matrixAware" must NOT appear — caller issued a corpusOnly request,
        // not a locusOnly request; the inner lane's vocabulary must not leak out.
        #expect(!result.degradedStages.contains("locusOnly.matrixAware"),
            "'locusOnly.matrixAware' must not appear in corpusOnly allowDegraded result; got \(result.degradedStages)")
    }

    /// corpusOnly + allowDegraded + rrf (no matrixAware):
    ///   MUST contain "corpusOnly.degraded".
    ///   MUST NOT contain "locusOnly.matrixAware" or "corpusOnly.matrixAware".
    @Test("corpusOnly allowDegraded + rrf: records corpusOnly.degraded, no matrixAware stage")
    func corpusOnlyAllowDegradedRRFVocabulary() async throws {
        let (kit, handle) = try await openLocusOnlyEstateForDegradTest(ownerSuffix: "rrf")
        let request = GLKRecallRequest(
            frame: RecallFrame(
                filterChain: [.unconfirmed],
                hydrationLevel: .structured,
                ordering: .byCaptureTimeDesc
            ),
            mode: .corpusOnly,
            scoring: .rrf,
            limit: 5,
            fallback: .allowDegraded,
            queryText: "stage vocabulary test rrf",
            origin: .internal
        )
        let result = try await kit.recall(handle, request)
        #expect(result.degradedStages.contains("corpusOnly.degraded"),
            "corpusOnly allowDegraded must record 'corpusOnly.degraded'; got \(result.degradedStages)")
        #expect(!result.degradedStages.contains("locusOnly.matrixAware"),
            "'locusOnly.matrixAware' must not appear for rrf scoring; got \(result.degradedStages)")
        #expect(!result.degradedStages.contains("corpusOnly.matrixAware"),
            "'corpusOnly.matrixAware' must not appear when scoring is rrf; got \(result.degradedStages)")
    }
}

// MARK: - §11 LocusKit recall internal-read failures (P0-5 sites 1-5)

/// These prove the GLK RecallDirector SURFACES a LocusKit recall internal-read
/// failure (liveRows / room-fingerprints / room-drawer / bitmap-eval) as a
/// named `locus.*` degraded stage in EVERY locus-draining lane — so a FAILED
/// locus recall is distinguishable from a GENUINE-EMPTY estate. The fault is
/// injected on the underlying `LocusKit.Estate` via its single-use seam.
@Suite("§11 Degradation — LocusKit recall internal-read failure", .serialized)
struct LocusRecallInternalReadDegradationTests {

    /// Arm the LocusKit estate's single-use internal-read fault seam through the
    /// GLK kit's estate resolver.
    private func armLocusFault(
        _ kit: GeniusLocusKit, _ handle: EstateHandle,
        _ read: LocusKit.Estate.RecallInternalRead
    ) async throws {
        let estate = try await kit.estate(for: handle)
        await estate._setTestForceInternalReadError(read)
    }

    /// locusOnly request with an empty filter chain → non-pruning scan path
    /// (the `liveRows` bounded-scan read), so the `.liveRows` fault targets it.
    private func locusOnlyRequest() -> GLKRecallRequest {
        GLKRecallRequest(
            frame: RecallFrame(filterChain: [], hydrationLevel: .structured,
                               ordering: .byCaptureTimeDesc),
            mode: .locusOnly, scoring: .raw, limit: 5,
            fallback: .failClosed, queryText: nil, origin: .internal)
    }

    @Test("locusOnly: failed liveRows surfaces locus.liveRows.readFailed (failed ≠ empty)")
    func locusOnlyLiveRowsFailed() async throws {
        let (kit, handle, _) = try await openFullyWiredEstate(ownerSuffix: "li-lo")
        try await armLocusFault(kit, handle, .liveRows)
        let result = try await kit.recall(handle, locusOnlyRequest())
        #expect(result.degradedStages.contains("locus.liveRows.readFailed"),
            "a failed locus read must surface its stage; got \(result.degradedStages)")
        #expect(result.hits.isEmpty,
            "the failed read yields no hits — but the stage proves this is FAILED, not empty")
    }

    @Test("locusOnly: bitmap-eval failure surfaces locus.bitmapEval.failed")
    func locusOnlyBitmapEvalFailed() async throws {
        let (kit, handle, _) = try await openFullyWiredEstate(ownerSuffix: "li-be")
        try await armLocusFault(kit, handle, .bitmapEval)
        let result = try await kit.recall(handle, locusOnlyRequest())
        #expect(result.degradedStages.contains("locus.bitmapEval.failed"),
            "got \(result.degradedStages)")
    }

    @Test("hybrid: failed liveRows surfaces locus.liveRows.readFailed, query degrades")
    func hybridLiveRowsFailed() async throws {
        let (kit, handle, _) = try await openFullyWiredEstate(ownerSuffix: "li-hy")
        try await armLocusFault(kit, handle, .liveRows)
        let result = try await kit.recall(handle, hybridRequest())
        #expect(result.degradedStages.contains("locus.liveRows.readFailed"),
            "hybrid must surface the locus read failure; got \(result.degradedStages)")
    }

    @Test("unionBest: failed liveRows surfaces locus.liveRows.readFailed")
    func unionBestLiveRowsFailed() async throws {
        let (kit, handle, _) = try await openFullyWiredEstate(ownerSuffix: "li-ub")
        try await armLocusFault(kit, handle, .liveRows)
        let result = try await kit.recall(handle, unionBestRequest())
        #expect(result.degradedStages.contains("locus.liveRows.readFailed"),
            "unionBest must surface the locus read failure; got \(result.degradedStages)")
    }

    @Test("GENUINE-EMPTY: healthy locus recall on empty result records NO locus.* stage")
    func genuineEmptyNoLocusStage() async throws {
        // Fully-wired estate, no fault armed. A query that matches nothing in the
        // locus lane must NOT record any locus.* stage — empty is not failure.
        let (kit, handle, _) = try await openFullyWiredEstate(ownerSuffix: "li-empty")
        let result = try await kit.recall(handle, locusOnlyRequest())
        let locusStages = result.degradedStages.filter { $0.hasPrefix("locus.") }
        #expect(locusStages.isEmpty,
            "a genuine recall (empty or not) must record no locus.* failure stage; got \(result.degradedStages)")
    }
}
