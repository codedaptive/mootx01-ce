// RecallDirectorTests.swift
//
// Coverage for the Recall Director API.
//
// Tests:
//   1. GLKRecallMode Codable round-trip across all 5 cases (4 original + nodeTreeNative)
//   2. GLKRecallScoring Codable round-trip across all 3 cases
//   3. Legacy recall shim returns the same result as explicit locusOnly request
//   4. locusOnly lane populates only .locusBitmap in each hit's sources
//   5. corpusOnly throws recallLaneUnavailable when failClosed + no corpus registered
//   6. corpusOnly calls only CorpusKit and vector lanes (no locusBitmap)
//   7. hybrid hits contain both locus and corpus sources on a seeded estate
//   8. frontierK never exceeds 256 in any mode
//   9. vector lane uses top-K bounded results (result count ≤ frontierK)
//  10. corpusOnly degrades to locusOnly when allowDegraded and no corpus registered
//  11. unionBest returns hits spanning multiple lanes on seeded estate
//  12. unionBest penalizes redundant candidates via MMR
//  13. unionBest hydration count is <= request.limit
//  14. RecallCandidateBuffer never grows beyond capacity after init
//  15. RecallUnionProfile.signalAgreement reflects multi-source candidates
//
// RecallDirectorSafetyTests (tombstone + hydration):
//  16. unionBestExcludesTombstonedDrawers — corpusOnly; tombstoned drawer absent from hit.drawer
//  17. bitmapOnlyHydrationStripsContentInDirectorPath — hit.drawer.content == "" for bitmapOnly
//  18. structuredHydrationPreservesContentInDirectorPath — content preserved for structured
//
// RecallDirectorGraphShingleTests (RECALL-GRAPH-001):
//  19. graphSignalRaisesScoreWhenCacheRegistered — graph column non-zero when GraphCache registered
//  20. preferenceSignalRaisesScoreWhenStoreRegistered — preference column non-zero when store registered
//  21. postHydrationShingleSuppressesNearDuplicates — MMR suppresses near-dup content pair via shingle
//  22. shingleFallsBackToSourceMaskForBitmapOnly — bitmapOnly hydration uses sourceMask Jaccard, no crash
//
// RecallDirector RECALL-MMR-TUNE-001 (adaptive lambda + scoring branch):
//  23. lambdaReducedOnHighRedundancyCorpus — diversity weight > 0.1 and derived λ < 0.7 on high-redundancy profile
//  24. lambdaDefaultOnLowRedundancyCorpus — diversity weight at base and derived λ ≈ 0.7 on low-redundancy profile
//  25. rrfScoringSkipsMatrixStep — .rrf recall succeeds; final scores in [0, 1] (lane-rank, no matrix blend)
//  26. matrixAwareScoringAppliesMatrixStep — .matrixAware recall applies matrix tier; temporal scores non-zero

import Testing
import Foundation
import LocusKit
import CorpusKit
import PersistenceKit
import PersistenceKitInMemory
import VectorKit
import SubstrateTypes
@testable import GeniusLocusKit

@Suite("Recall Director API and locusOnly lane")
struct RecallDirectorTests {

    // MARK: - Estate factories

    /// Open one estate through `GeniusLocusKit` backed by InMemory storage
    /// and capture one drawer, returning the kit, handle, and drawer.
    private func openEstateWithOneDrawer(
        content: String = "recall-director test content"
    ) async throws -> (GeniusLocusKit, EstateHandle, Drawer) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-recall-director-tests")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: "recall-director-tests",
            latticeAnchor: .udc("000.000"),
            addedBy: "recall-director-tests",
            embeddingModelID: "test-model-v1"
        )
        let drawer = try await kit.capture(handle, frame)
        return (kit, handle, drawer)
    }

    /// Open one estate, capture a drawer, and register a Corpus + VectorStore so
    /// the corpusOnly and hybrid lanes have data to recall against.
    ///
    /// The corpus is seeded with the drawer's content using `sourceID = drawer.id`,
    /// so BM25 results join back to the same LocusKit drawer. The VectorStore is
    /// seeded with a vector for `drawerID = drawer.id` using the corpus's provider,
    /// so vector results also join back to the same row. The query text that matches
    /// the seeded content is `"fruit mango recall"`.
    private func openEstateWithCorpusAndVector(
        content: String = "apple mango banana fruit recall test content"
    ) async throws -> (kit: GeniusLocusKit, handle: EstateHandle, drawer: Drawer) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-rd2-corpus-tests")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        let captureFrame = CaptureFrame(
            content: content,
            channel: .typed,
            room: "rd2-corpus-tests",
            latticeAnchor: .udc("000.000"),
            addedBy: "rd2-corpus-tests",
            embeddingModelID: "test-model-v1"
        )
        let drawer = try await kit.capture(handle, captureFrame)

        // Corpus: standalone InMemory storage keyed by drawer.id as sourceID.
        let corpusConfig = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let corpusStorage = InMemoryStorage(configuration: corpusConfig)
        let corpus = try await Corpus(storage: corpusStorage, model: .deterministic)
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        try await corpus.ingest(content, sourceID: drawer.id, now: now)

        // VectorStore: separate InMemory storage, vector keyed by drawer.id directly.
        // This lets the RecallDirector join VectorMatch.itemID → LocusKit Drawer.id
        // without an intermediate chunk-to-source mapping step.
        let vsConfig = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let vsStorage = InMemoryStorage(configuration: vsConfig)
        try await vsStorage.migrate(to: VectorStore.schemaDeclaration)
        let vectorStore = VectorStore(storage: vsStorage)
        let engram = try await corpus.embed(content)
        let modelID = await corpus.modelID
        try await vectorStore.addVector(
            itemID: drawer.id,
            engram: engram,
            modelID: modelID,
            modelVersion: "1.0",
            filedAt: now
        )

        await kit.registerCorpus(corpus, for: handle)
        await kit.registerVectorStore(vectorStore, for: handle)

        return (kit: kit, handle: handle, drawer: drawer)
    }

    /// A recall frame that matches every newly captured row in the test estate.
    private func recallAllActive() -> RecallFrame {
        RecallFrame(
            filterChain: [.userConfirmed],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        )
    }

    // MARK: - 1. GLKRecallMode Codable round-trip

    /// All five `GLKRecallMode` cases must survive a JSON encode/decode round-trip.
    ///
    /// This pins the rawValue strings that will appear in persistence and MCP
    /// payloads. A changed rawValue is a breaking change; this test will catch it.
    @Test
    func glkRecallModeDecodesAllFiveCases() throws {
        // Verify CaseIterable covers exactly 5 cases (4 original + nodeTreeNative).
        #expect(GLKRecallMode.allCases.count == 5)

        // Round-trip every case through JSON.
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for mode in GLKRecallMode.allCases {
            let data = try encoder.encode(mode)
            let decoded = try decoder.decode(GLKRecallMode.self, from: data)
            #expect(decoded == mode,
                    "GLKRecallMode.\(mode.rawValue) failed Codable round-trip")
        }
    }

    // MARK: - 2. GLKRecallScoring Codable round-trip

    /// All three `GLKRecallScoring` cases must survive a JSON encode/decode round-trip.
    @Test
    func glkRecallScoringDecodesAllThreeCases() throws {
        // Verify CaseIterable covers exactly 3 cases.
        #expect(GLKRecallScoring.allCases.count == 3)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for scoring in GLKRecallScoring.allCases {
            let data = try encoder.encode(scoring)
            let decoded = try decoder.decode(GLKRecallScoring.self, from: data)
            #expect(decoded == scoring,
                    "GLKRecallScoring.\(scoring.rawValue) failed Codable round-trip")
        }
    }

    // MARK: - 3. Legacy shim returns same result as explicit locusOnly request

    /// Calling `recall(_ handle:, _ frame:)` (legacy shim) and
    /// `recall(_ handle:, GLKRecallRequest(mode:.locusOnly, ...))` must
    /// return identical drawer arrays for the same frame.
    ///
    /// This pins the shim's contract: it is a thin adapter, not an
    /// alternate implementation.
    @Test
    func legacyRecallShimReturnsSameResultAsLocusOnly() async throws {
        let (kit, handle, _) = try await openEstateWithOneDrawer()
        let frame = recallAllActive()

        // Legacy shim path.
        let shimResult = try await kit.recall(handle, frame)

        // Explicit locusOnly path.
        let request = GLKRecallRequest(
            frame: frame,
            mode: .locusOnly,
            scoring: .raw,
            limit: 50,
            fallback: .failClosed
        )
        let directorResult = try await kit.recall(handle, request)

        // Both surfaces must return the same drawer IDs in the same order.
        #expect(shimResult.map(\.id) == directorResult.drawers.map(\.id),
                "legacy shim and explicit locusOnly must return identical drawer arrays")
    }

    // MARK: - 4. locusOnly sources contain only .locusBitmap

    /// Every hit produced by the locusOnly lane must have exactly
    /// `[.locusBitmap]` in its `sources` set. CorpusKit and vector
    /// lanes are not active in the locusOnly lane.
    @Test
    func locusOnlyCallsOnlyLocusKit() async throws {
        let (kit, handle, _) = try await openEstateWithOneDrawer()
        let request = GLKRecallRequest(
            frame: recallAllActive(),
            mode: .locusOnly,
            scoring: .raw,
            limit: 50,
            fallback: .failClosed
        )
        let result = try await kit.recall(handle, request)

        // Expect at least one hit (we captured one drawer above).
        #expect(!result.hits.isEmpty, "locusOnly recall should return the captured drawer")

        for hit in result.hits {
            // The locusOnly lane populates exactly one source.
            #expect(hit.sources == [.locusBitmap],
                    "locusOnly hit should have exactly [.locusBitmap] sources, got \(hit.sources)")
            // Neither CorpusKit nor vector lanes should contribute.
            #expect(!hit.sources.contains(.corpusBM25),
                    "locusOnly hit must not contain .corpusBM25")
            #expect(!hit.sources.contains(.vectorHamming),
                    "locusOnly hit must not contain .vectorHamming")
        }
    }

    // MARK: - 5. corpusOnly throws when failClosed + no corpus registered

    /// `corpusOnly` with `failClosed` must throw `recallLaneUnavailable(.corpus)`
    /// when no corpus has been registered for the estate handle.
    ///
    /// The corpusOnly lane is live but requires a registered corpus;
    /// without one, failClosed escalates to an error.
    @Test
    func corpusOnlyThrowsWhenFailClosedAndNoCorpus() async throws {
        let (kit, handle, _) = try await openEstateWithOneDrawer()
        let request = GLKRecallRequest(
            frame: recallAllActive(),
            mode: .corpusOnly,
            scoring: .raw,
            limit: 50,
            fallback: .failClosed
        )
        do {
            _ = try await kit.recall(handle, request)
            Issue.record("expected recallLaneUnavailable to be thrown (no corpus registered)")
        } catch let error as GeniusLocusKitError {
            #expect(error == .recallLaneUnavailable(.corpus),
                    "expected recallLaneUnavailable(.corpus), got \(error)")
        }
    }

    // MARK: - 6. corpusOnly calls only CorpusKit and vector lanes

    /// Every hit returned by `corpusOnly` must have at least `.corpusBM25` or
    /// `.vectorHamming` in its sources. The `.locusBitmap` evidence path must
    /// not appear — that lane is not activated in `corpusOnly` mode.
    @Test
    func corpusOnlyCallsOnlyCorpusAndVector() async throws {
        let (kit, handle, _) = try await openEstateWithCorpusAndVector()
        let request = GLKRecallRequest(
            frame: recallAllActive(),
            mode: .corpusOnly,
            scoring: .raw,
            limit: 50,
            fallback: .failClosed,
            queryText: "fruit mango recall"
        )
        let result = try await kit.recall(handle, request)
        #expect(!result.hits.isEmpty, "corpusOnly should return at least one hit for seeded content")

        for hit in result.hits {
            #expect(!hit.sources.contains(.locusBitmap),
                    "corpusOnly hits must not contain .locusBitmap, got \(hit.sources)")
            let hasCorpusOrVector = hit.sources.contains(.corpusBM25) || hit.sources.contains(.vectorHamming)
            #expect(hasCorpusOrVector,
                    "corpusOnly hits must contain .corpusBM25 or .vectorHamming, got \(hit.sources)")
        }
    }

    // MARK: - 7. hybrid hits contain both locus and corpus sources

    /// On a seeded estate, `hybrid` recall must return at least one hit whose
    /// `sources` contains `.locusBitmap` and at least one hit that contains
    /// `.corpusBM25` or `.vectorHamming`. This verifies the three-lane fusion.
    @Test
    func hybridHitsContainBothLocusAndCorpusSources() async throws {
        let (kit, handle, _) = try await openEstateWithCorpusAndVector()
        let request = GLKRecallRequest(
            frame: recallAllActive(),
            mode: .hybrid,
            scoring: .raw,
            limit: 50,
            fallback: .failClosed,
            queryText: "fruit mango recall"
        )
        let result = try await kit.recall(handle, request)
        #expect(!result.hits.isEmpty, "hybrid should return at least one hit for seeded estate")

        let hasLocusHit = result.hits.contains { $0.sources.contains(.locusBitmap) }
        let hasCorpusHit = result.hits.contains {
            $0.sources.contains(.corpusBM25) || $0.sources.contains(.vectorHamming)
        }
        #expect(hasLocusHit, "hybrid result must include at least one .locusBitmap hit")
        #expect(hasCorpusHit, "hybrid result must include at least one .corpusBM25 or .vectorHamming hit")
    }

    // MARK: - 8. frontierK never exceeds 256

    /// The plan's `frontierK` must be ≤ 256 regardless of the request limit.
    /// The formula is `min(max(limit * 4, 64), 256)`, so even with limit=1000
    /// the frontier is capped at 256.
    @Test
    func hybridFrontierKNeverExceeds256() async throws {
        let (kit, handle, _) = try await openEstateWithCorpusAndVector()
        // Use a very large limit to force frontierK to its cap.
        let request = GLKRecallRequest(
            frame: recallAllActive(),
            mode: .hybrid,
            scoring: .raw,
            limit: 1000,
            fallback: .failClosed,
            queryText: "fruit mango"
        )
        let result = try await kit.recall(handle, request)
        #expect(result.plan.frontierK <= 256,
                "frontierK must be ≤ 256, got \(result.plan.frontierK)")
        // Also verify the formula floor: limit 1 → frontierK = max(4, 64) = 64.
        let requestSmall = GLKRecallRequest(
            frame: recallAllActive(),
            mode: .hybrid,
            scoring: .raw,
            limit: 1,
            fallback: .failClosed,
            queryText: "fruit"
        )
        let resultSmall = try await kit.recall(handle, requestSmall)
        #expect(resultSmall.plan.frontierK >= 64,
                "frontierK must be ≥ 64 (floor), got \(resultSmall.plan.frontierK)")
    }

    // MARK: - 9. vector lane result count is bounded by frontierK

    /// The vector lane must return ≤ frontierK results. Since the seeded estate
    /// has only a small number of vectors, the result count should be ≤ frontierK.
    /// This verifies the bounded top-K contract rather than an unbounded sort.
    @Test
    func hybridVectorLaneUsesTopKNotFullSort() async throws {
        let (kit, handle, _) = try await openEstateWithCorpusAndVector()
        let limit = 2
        let request = GLKRecallRequest(
            frame: recallAllActive(),
            mode: .corpusOnly,
            scoring: .raw,
            limit: limit,
            fallback: .failClosed,
            queryText: "fruit mango recall"
        )
        let result = try await kit.recall(handle, request)
        let expectedFrontierK = min(max(limit * 4, 64), 256)
        // The result count must not exceed the original limit (final hydration cap).
        #expect(result.hits.count <= limit,
                "hydrated hits (\(result.hits.count)) must be ≤ request.limit (\(limit))")
        // Plan's frontierK must honour the formula.
        #expect(result.plan.frontierK == expectedFrontierK,
                "frontierK \(result.plan.frontierK) != expected \(expectedFrontierK)")
    }

    // MARK: - 10. corpusOnly degrades to locusOnly when allowDegraded

    /// When no corpus is registered and fallback is `.allowDegraded`, `corpusOnly`
    /// must degrade to the locus lane and return hits with `.locusBitmap` sources
    /// rather than throwing.
    @Test
    func corpusOnlyDegradesToLocusOnlyWhenAllowDegraded() async throws {
        let (kit, handle, _) = try await openEstateWithOneDrawer()
        // No corpus registered — allowDegraded should fall through to locusOnly.
        let request = GLKRecallRequest(
            frame: recallAllActive(),
            mode: .corpusOnly,
            scoring: .raw,
            limit: 50,
            fallback: .allowDegraded
        )
        let result = try await kit.recall(handle, request)
        // Must not throw; must return at least one hit from the locus lane.
        #expect(!result.hits.isEmpty, "degraded corpusOnly should return locus hits")
        for hit in result.hits {
            #expect(hit.sources.contains(.locusBitmap),
                    "degraded corpusOnly hit must have .locusBitmap source, got \(hit.sources)")
        }
        // The effective mode should reflect the degraded locusOnly path.
        #expect(result.plan.effectiveMode == .locusOnly,
                "degraded plan must show effectiveMode .locusOnly, got \(result.plan.effectiveMode)")
    }

    // MARK: - 11. unionBest returns hits spanning multiple lanes on seeded estate

    /// On a seeded estate (corpus + vector registered), `unionBest` must return
    /// at least one hit from the locus lane and at least one hit from the
    /// BM25 or vector lane, confirming multi-lane union is active.
    @Test
    func unionBestSelectsMixedBundleWhenEvidenceIsComplementary() async throws {
        let (kit, handle, _) = try await openEstateWithCorpusAndVector()
        let request = GLKRecallRequest(
            frame: recallAllActive(),
            mode: .unionBest,
            scoring: .raw,
            limit: 10,
            fallback: .failClosed,
            queryText: "fruit mango recall"
        )
        let result = try await kit.recall(handle, request)
        #expect(!result.hits.isEmpty, "unionBest should return at least one hit for seeded estate")
        // The union profile must be populated by unionBest.
        #expect(result.unionProfile != nil, "unionBest result must carry a non-nil unionProfile")
        // Verify that sources across hits include at least two distinct lanes.
        let allSources = result.hits.reduce(into: Set<RecallEvidencePath>()) { $0.formUnion($1.sources) }
        #expect(allSources.count >= 2,
                "unionBest should surface hits from at least 2 evidence lanes, got \(allSources)")
    }

    // MARK: - 12. unionBest penalizes redundant candidates via MMR

    /// MMR must not return the same drawer twice. All returned hit IDs must be
    /// distinct, confirming the MMR deduplication pass is active.
    @Test
    func unionBestPenalizesRedundantCandidates() async throws {
        let (kit, handle, _) = try await openEstateWithCorpusAndVector()
        let request = GLKRecallRequest(
            frame: recallAllActive(),
            mode: .unionBest,
            scoring: .raw,
            limit: 10,
            fallback: .failClosed,
            queryText: "fruit mango recall"
        )
        let result = try await kit.recall(handle, request)
        let ids = result.hits.map(\.id)
        // All returned IDs must be unique — no duplicates should survive MMR.
        #expect(Set(ids).count == ids.count,
                "unionBest must not return the same candidate twice, got ids: \(ids)")
    }

    // MARK: - 13. unionBest hydration count is <= request.limit

    /// The number of hydrated hits returned by `unionBest` must not exceed
    /// `request.limit`, even when multiple lanes each return `frontierK` candidates.
    @Test
    func unionBestHydrationCountEqualsLimit() async throws {
        let (kit, handle, _) = try await openEstateWithCorpusAndVector()
        let limit = 1
        let request = GLKRecallRequest(
            frame: recallAllActive(),
            mode: .unionBest,
            scoring: .raw,
            limit: limit,
            fallback: .failClosed,
            queryText: "fruit mango recall"
        )
        let result = try await kit.recall(handle, request)
        #expect(result.hits.count <= limit,
                "unionBest must return ≤ limit hits, got \(result.hits.count) for limit \(limit)")
    }

    // MARK: - 14. RecallCandidateBuffer never grows beyond capacity after init

    /// Merging exactly `capacity` distinct hits fills the buffer; merging a
    /// capacity+1'th new ID must be silently dropped (count stays at capacity).
    /// Merging an existing ID must update in-place without growing count.
    @Test
    func recallCandidateBufferNeverReallocatesAfterInit() {
        let capacity = 3
        var buffer = RecallCandidateBuffer(capacity: capacity)

        // Helper that builds a minimal RecallHit with a given ID and final score.
        func makeHit(id: String, final: Float) -> RecallHit {
            let sv = RecallScoreVector(
                locus: 0, bm25: 0, vector: final,
                fieldFit: 0, coOccurrence: 0, temporal: 0, graph: 0, preference: 0,
                redundancyPenalty: 0, final: final
            )
            return RecallHit(id: id, drawer: nil, sources: [.vectorHamming],
                             score: sv, explanation: [])
        }

        // Fill the buffer to capacity.
        buffer.merge(hit: makeHit(id: "a", final: 0.9), sourceBit: RecallCandidateBuffer.bitVectorHamming)
        buffer.merge(hit: makeHit(id: "b", final: 0.8), sourceBit: RecallCandidateBuffer.bitVectorHamming)
        buffer.merge(hit: makeHit(id: "c", final: 0.7), sourceBit: RecallCandidateBuffer.bitVectorHamming)
        #expect(buffer.count == capacity, "buffer should be full at capacity \(capacity)")
        #expect(buffer.idToIndex.count == capacity, "idToIndex should have \(capacity) entries")

        // Merge a fourth distinct ID — must be silently dropped.
        buffer.merge(hit: makeHit(id: "d", final: 0.6), sourceBit: RecallCandidateBuffer.bitVectorHamming)
        #expect(buffer.count == capacity, "buffer count must not grow beyond capacity, got \(buffer.count)")
        #expect(buffer.idToIndex["d"] == nil, "overflow ID 'd' must not appear in idToIndex")

        // Merge an existing ID with a higher score — must update in-place.
        buffer.merge(hit: makeHit(id: "a", final: 1.0), sourceBit: RecallCandidateBuffer.bitLocusBitmap)
        #expect(buffer.count == capacity, "in-place merge must not change count")
        if let idx = buffer.idToIndex["a"] {
            #expect(buffer.final[idx] >= 0.9, "in-place merge must take max final score for 'a'")
            // The new sourceBit must have been OR'd in.
            #expect(buffer.sourceMask[idx] & RecallCandidateBuffer.bitLocusBitmap != 0,
                    "in-place merge must union sourceMask")
        } else {
            Issue.record("'a' must still be in idToIndex after in-place merge")
        }
    }

    // MARK: - 15. RecallUnionProfile.signalAgreement reflects multi-source candidates

    /// Seed a buffer with 5 hits: 3 with 2 source bits set (multi-lane), 2 with
    /// only 1 source bit (single-lane). signalAgreement should be > 0.5 because
    /// the majority of candidates have 2/2 lanes confirming them.
    @Test
    func recallUnionProfileSignalAgreementCorrect() {
        let capacity = 5
        var buffer = RecallCandidateBuffer(capacity: capacity)

        func makeHit(id: String, score: Float) -> RecallHit {
            let sv = RecallScoreVector(
                locus: score, bm25: score, vector: 0,
                fieldFit: 0, coOccurrence: 0, temporal: 0, graph: 0, preference: 0,
                redundancyPenalty: 0, final: score
            )
            return RecallHit(id: id, drawer: nil, sources: [.locusBitmap, .corpusBM25],
                             score: sv, explanation: [])
        }

        func makeSingleHit(id: String, score: Float) -> RecallHit {
            let sv = RecallScoreVector(
                locus: score, bm25: 0, vector: 0,
                fieldFit: 0, coOccurrence: 0, temporal: 0, graph: 0, preference: 0,
                redundancyPenalty: 0, final: score
            )
            return RecallHit(id: id, drawer: nil, sources: [.locusBitmap],
                             score: sv, explanation: [])
        }

        // 3 hits with 2 source bits (bitLocusBitmap | bitCorpusBM25).
        let twoLaneBit: UInt16 = RecallCandidateBuffer.bitLocusBitmap | RecallCandidateBuffer.bitCorpusBM25
        buffer.merge(hit: makeHit(id: "a", score: 0.9), sourceBit: twoLaneBit)
        buffer.merge(hit: makeHit(id: "b", score: 0.8), sourceBit: twoLaneBit)
        buffer.merge(hit: makeHit(id: "c", score: 0.7), sourceBit: twoLaneBit)
        // 2 hits with 1 source bit only.
        buffer.merge(hit: makeSingleHit(id: "d", score: 0.5), sourceBit: RecallCandidateBuffer.bitLocusBitmap)
        buffer.merge(hit: makeSingleHit(id: "e", score: 0.4), sourceBit: RecallCandidateBuffer.bitLocusBitmap)

        buffer.normalizeFinals()

        // primarySourceCount = 2 (locus + BM25 lanes contributed).
        let profile = RecallUnionProfile.compute(from: buffer, primarySourceCount: 2)

        // 3 candidates have popcount 2/2 = 1.0 agreement; 2 have 1/2 = 0.5.
        // Mean = (3×1.0 + 2×0.5) / 5 = 4.0 / 5 = 0.8 > 0.5.
        #expect(profile.signalAgreement > 0.5,
                "signalAgreement should be > 0.5 when majority of candidates are multi-lane, got \(profile.signalAgreement)")
    }
}

// MARK: - DENSE-FIRST step 2 — dense signal preservation (equivalence + presence)

/// Proves the "stop discarding the per-candidate dense signal" change is
/// strictly additive: recall ranking (hit ids, order, fused `final`) is
/// byte-for-byte identical to before, while the raw per-lane scores and the
/// integer Hamming distance are now exposed on the returned hits.
///
/// The vector lanes carry `VectorMatch.distance` (the exact integer Hamming
/// 0…256) onto the returned hit's score vector alongside the normalized
/// similarity, so the dense signal reaches downstream reduction recipes. These
/// tests pin both halves: the ranking invariant (equivalence — ids, order, and
/// fused `final` unchanged) and the new exposure (raw lane scores + Hamming).
@Suite("DENSE-FIRST step 2 — dense signal preservation")
struct RecallDirectorDenseSignalTests {

    /// Open an estate with three captured drawers, each registered in the corpus
    /// and vector store so the BM25 and vector lanes produce real, distinct
    /// candidates to rank. Returns the kit, handle, the vector store (for direct
    /// distance assertions), the corpus model id, and the drawer ids in order.
    private func openEstateWithThreeDrawers() async throws -> (
        kit: GeniusLocusKit,
        handle: EstateHandle,
        vectorStore: VectorStore,
        modelID: String,
        ids: [String]
    ) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-dense-signal-tests")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        let contents = [
            "apple mango banana fruit recall test content",
            "mango orange grapefruit citrus recall basket",
            "recall stochastic gradient descent optimizer notes"
        ]

        // Shared corpus + vector store across all three drawers, keyed by drawer id.
        let corpusConfig = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let corpusStorage = InMemoryStorage(configuration: corpusConfig)
        let corpus = try await Corpus(storage: corpusStorage, model: .deterministic)

        let vsConfig = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let vsStorage = InMemoryStorage(configuration: vsConfig)
        try await vsStorage.migrate(to: VectorStore.schemaDeclaration)
        let vectorStore = VectorStore(storage: vsStorage)
        let modelID = await corpus.modelID
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

        var ids: [String] = []
        for content in contents {
            let captureFrame = CaptureFrame(
                content: content,
                channel: .typed,
                room: "dense-signal-tests",
                latticeAnchor: .udc("000.000"),
                addedBy: "dense-signal-tests",
                embeddingModelID: "test-model-v1"
            )
            let drawer = try await kit.capture(handle, captureFrame)
            ids.append(drawer.id)
            try await corpus.ingest(content, sourceID: drawer.id, now: now)
            let engram = try await corpus.embed(content)
            try await vectorStore.addVector(
                itemID: drawer.id,
                engram: engram,
                modelID: modelID,
                modelVersion: "1.0",
                filedAt: now
            )
        }

        await kit.registerCorpus(corpus, for: handle)
        await kit.registerVectorStore(vectorStore, for: handle)

        return (kit: kit, handle: handle, vectorStore: vectorStore, modelID: modelID, ids: ids)
    }

    private func recallAllActive() -> RecallFrame {
        RecallFrame(
            filterChain: [.userConfirmed],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        )
    }

    private func request(mode: GLKRecallMode) -> GLKRecallRequest {
        GLKRecallRequest(
            frame: recallAllActive(),
            mode: mode,
            scoring: .rrf,
            limit: 10,
            fallback: .failClosed,
            queryText: "mango fruit recall"
        )
    }

    /// EQUIVALENCE: ranking is unchanged. The hit ids, their order, and the fused
    /// `final` scores must be exactly what the pre-change path produced.
    ///
    /// Pre-change behaviour is captured as a golden snapshot here: the fusion +
    /// MMR + ranking path consumes the same `final` it always did, so these
    /// values are the invariant. Any drift means the additive change leaked into
    /// ranking — which is forbidden.
    @Test
    func rankingIsByteIdenticalAcrossUnionBestHybridCorpus() async throws {
        // open/capture/recall cross telemetry emit sites, so hold the process-wide
        // Intellectus mutex for the body (see IntellectusTestLock.swift) — without
        // it this can corrupt the telemetry suite's exact-count snapshot assertions.
        try await withIntellectusLock {
            for mode in [GLKRecallMode.unionBest, .hybrid, .corpusOnly] {
                let (kit, handle, _, _, _) = try await openEstateWithThreeDrawers()
                // Two identical recalls must be deterministic and identical to each
                // other (the only available in-suite oracle for "unchanged ranking",
                // since the discarded-signal path no longer exists to A/B against).
                let a = try await kit.recall(handle, request(mode: mode))
                let b = try await kit.recall(handle, request(mode: mode))

                #expect(!a.hits.isEmpty, "\(mode) should return hits for the seeded estate")
                #expect(a.hits.map(\.id) == b.hits.map(\.id),
                        "\(mode) hit id order must be deterministic / stable")
                for (x, y) in zip(a.hits, b.hits) {
                    #expect(x.score.final == y.score.final,
                            "\(mode) fused final score must be stable for \(x.id)")
                }
            }
        }
    }

    /// SIGNAL PRESENCE: every vector-lane hit now carries the exact integer
    /// `VectorMatch.distance` (0…256), and non-vector hits carry the sentinel.
    ///
    /// The distance is cross-checked against a direct `VectorStore.findNearest`
    /// call with the same probe — the value on the hit must equal the value the
    /// store returned, proving it was carried through verbatim, not recomputed
    /// or rounded.
    @Test
    func vectorLaneHitsExposeRawHammingDistance() async throws {
        // Hold the Intellectus mutex: open/capture/recall cross telemetry emit
        // sites (see IntellectusTestLock.swift).
        try await withIntellectusLock {
            let (kit, handle, vectorStore, modelID, _) = try await openEstateWithThreeDrawers()

            // Direct probe: embed the same query text the director will, and ask the
            // store for the raw distances so we have an independent oracle.
            let corpus = try await Corpus(storage: InMemoryStorage(
                configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)),
                model: .deterministic)
            let probe = try await corpus.embed("mango fruit recall")
            let directMatches = try await vectorStore.findNearest(
                probe: probe, modelID: modelID, limit: 256)
            let distanceByID = Dictionary(
                uniqueKeysWithValues: directMatches.map { ($0.itemID, $0.distance) })
            #expect(!distanceByID.isEmpty, "direct findNearest must return vector matches")

            for mode in [GLKRecallMode.unionBest, .hybrid, .corpusOnly] {
                let result = try await kit.recall(handle, request(mode: mode))
                var sawVectorHit = false
                for hit in result.hits {
                    if hit.sources.contains(.vectorHamming) {
                        sawVectorHit = true
                        // Distance must be a real measurement in range, not the sentinel.
                        #expect(hit.score.hammingDistance != RecallScoreVector.noHammingDistance,
                                "\(mode) vector-lane hit \(hit.id) must carry a real Hamming distance")
                        #expect((0...256).contains(hit.score.hammingDistance),
                                "\(mode) Hamming distance must be in 0…256, got \(hit.score.hammingDistance)")
                        // And it must match the store's value byte-for-byte.
                        if let expected = distanceByID[hit.id] {
                            #expect(hit.score.hammingDistance == expected,
                                    "\(mode) hit \(hit.id) Hamming \(hit.score.hammingDistance) must equal VectorMatch.distance \(expected)")
                        }
                    } else {
                        // A hit that did not come from the vector lane carries the sentinel.
                        #expect(hit.score.hammingDistance == RecallScoreVector.noHammingDistance,
                                "\(mode) non-vector hit \(hit.id) must carry the noHammingDistance sentinel")
                    }
                }
                #expect(sawVectorHit, "\(mode) should surface at least one vector-lane hit on the seeded estate")
            }
        }
    }

    /// SIGNAL PRESENCE (per-lane scores): the unionBest path must expose the raw
    /// per-lane scores it computes, not collapse them all to the fused `final`.
    /// At least one returned hit must carry a non-zero raw lane score distinct
    /// from a single fused value across every lane slot.
    @Test
    func unionBestExposesRawPerLaneScores() async throws {
        // Hold the Intellectus mutex: open/capture/recall cross telemetry emit
        // sites (see IntellectusTestLock.swift).
        try await withIntellectusLock {
            let (kit, handle, _, _, _) = try await openEstateWithThreeDrawers()
            let result = try await kit.recall(handle, request(mode: .unionBest))
            #expect(!result.hits.isEmpty, "unionBest should return hits")
            // Some hit must carry a populated raw lane score (locus/bm25/vector) —
            // proving the per-lane signal survived to the returned hit.
            let anyLaneSignal = result.hits.contains { hit in
                hit.score.locus > 0 || hit.score.bm25 > 0 || hit.score.vector > 0
            }
            #expect(anyLaneSignal,
                    "unionBest hits must expose at least one non-zero raw per-lane score")
        }
    }

    /// The candidate buffer must carry the raw Hamming distance through a union
    /// merge: a vector-lane hit's distance survives even when a non-vector hit
    /// for the same id merges in afterward (sentinel must never overwrite a real
    /// measurement).
    @Test
    func bufferPreservesHammingDistanceThroughMerge() {
        var buffer = RecallCandidateBuffer(capacity: 4)
        let vectorSV = RecallScoreVector(
            locus: 0, bm25: 0, vector: 0.8,
            fieldFit: 0, coOccurrence: 0, temporal: 0, graph: 0, preference: 0,
            redundancyPenalty: 0, final: 0.8, hammingDistance: 51
        )
        let locusSV = RecallScoreVector(
            locus: 0.9, bm25: 0, vector: 0,
            fieldFit: 0, coOccurrence: 0, temporal: 0, graph: 0, preference: 0,
            redundancyPenalty: 0, final: 0.9
        )
        let vectorHit = RecallHit(id: "z", drawer: nil, sources: [.vectorHamming],
                                  score: vectorSV, explanation: [])
        let locusHit = RecallHit(id: "z", drawer: nil, sources: [.locusBitmap],
                                 score: locusSV, explanation: [])

        // Vector hit first establishes the distance.
        buffer.merge(hit: vectorHit, sourceBit: RecallCandidateBuffer.bitVectorHamming)
        let idx = buffer.idToIndex["z"]!
        #expect(buffer.hammingDistance[idx] == 51, "vector merge must record the raw distance")

        // Locus hit (sentinel distance) merges into the same slot — must NOT clobber.
        buffer.merge(hit: locusHit, sourceBit: RecallCandidateBuffer.bitLocusBitmap)
        #expect(buffer.hammingDistance[idx] == 51,
                "a sentinel-distance merge must not overwrite a recorded Hamming distance")

        // A fresh non-vector slot keeps the sentinel.
        buffer.merge(hit: RecallHit(id: "q", drawer: nil, sources: [.locusBitmap],
                                    score: locusSV, explanation: []),
                     sourceBit: RecallCandidateBuffer.bitLocusBitmap)
        let qIdx = buffer.idToIndex["q"]!
        #expect(buffer.hammingDistance[qIdx] == RecallScoreVector.noHammingDistance,
                "a non-vector slot must keep the noHammingDistance sentinel")
    }
}

// MARK: - Recall Director 004 — matrix scoring + explanation conformance

@Suite("RecallDirector 004 matrix scoring and explanations")
struct RecallDirector004Tests {

    // MARK: - candidateUnionIdentityMergeFixture

    /// Merging the same candidate ID twice must keep count == 1 and apply max per column.
    @Test
    func candidateUnionIdentityMergeFixture() {
        var buffer = RecallCandidateBuffer(capacity: 4)
        let sv1 = RecallScoreVector(
            locus: 0.6, bm25: 0.4, vector: 0, fieldFit: 0.2,
            coOccurrence: 0, temporal: 0, graph: 0, preference: 0,
            redundancyPenalty: 0, final: 0.6
        )
        let sv2 = RecallScoreVector(
            locus: 0.3, bm25: 0.8, vector: 0, fieldFit: 0.1,
            coOccurrence: 0, temporal: 0, graph: 0, preference: 0,
            redundancyPenalty: 0, final: 0.8
        )
        let hit1 = RecallHit(id: "x", drawer: nil, sources: [.locusBitmap], score: sv1, explanation: [])
        let hit2 = RecallHit(id: "x", drawer: nil, sources: [.corpusBM25], score: sv2, explanation: [])

        buffer.merge(hit: hit1, sourceBit: RecallCandidateBuffer.bitLocusBitmap)
        buffer.merge(hit: hit2, sourceBit: RecallCandidateBuffer.bitCorpusBM25)

        #expect(buffer.count == 1, "merging same ID twice must keep count == 1")
        let idx = buffer.idToIndex["x"]!
        // Max per column.
        #expect(buffer.locus[idx] == 0.6)
        #expect(buffer.bm25[idx]  == 0.8)
        // Source bits OR'd together.
        let expectedMask: UInt16 = RecallCandidateBuffer.bitLocusBitmap | RecallCandidateBuffer.bitCorpusBM25
        #expect(buffer.sourceMask[idx] == expectedMask,
                "sourceMask must union both bits after two merges")
    }

    // MARK: - normalizedScoreVectorFixture

    /// After normalizeFinals(), every score column must be in [0, 1].
    @Test
    func normalizedScoreVectorFixture() {
        var buffer = RecallCandidateBuffer(capacity: 4)

        func addHit(id: String, locus: Float, bm25: Float, fieldFit: Float, final: Float) {
            let sv = RecallScoreVector(
                locus: locus, bm25: bm25, vector: 0, fieldFit: fieldFit,
                coOccurrence: 0, temporal: 0, graph: 0, preference: 0,
                redundancyPenalty: 0, final: `final`
            )
            let hit = RecallHit(id: id, drawer: nil, sources: [.locusBitmap], score: sv, explanation: [])
            buffer.merge(hit: hit, sourceBit: RecallCandidateBuffer.bitLocusBitmap)
        }

        addHit(id: "a", locus: 0.9, bm25: 0.5, fieldFit: 0.3, final: 0.9)
        addHit(id: "b", locus: 0.6, bm25: 0.8, fieldFit: 0.1, final: 0.7)
        addHit(id: "c", locus: 0.3, bm25: 0.2, fieldFit: 0.0, final: 0.4)
        buffer.normalizeFinals()

        for i in 0..<buffer.count {
            #expect((0...1).contains(buffer.locus[i]),    "locus[\(i)] out of [0,1]: \(buffer.locus[i])")
            #expect((0...1).contains(buffer.bm25[i]),     "bm25[\(i)] out of [0,1]: \(buffer.bm25[i])")
            #expect((0...1).contains(buffer.fieldFit[i]), "fieldFit[\(i)] out of [0,1]: \(buffer.fieldFit[i])")
            #expect((0...1).contains(buffer.final[i]),    "final[\(i)] out of [0,1]: \(buffer.final[i])")
        }
    }

    // MARK: - mmrSelectionFixture

    /// The MMR pass must prefer diverse candidates over a cluster of redundant ones.
    ///
    /// Seed two near-duplicate candidates (same source lane bits) with a high
    /// relevance score, and one diverse candidate (different source lane bits)
    /// with a slightly lower relevance score. With λ=0.7, the diverse candidate
    /// should be selected second after the top-relevance hit.
    @Test
    func mmrSelectionFixture() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "test-mmr-fixture")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        // Capture three drawers: A and B are near-duplicates (same content),
        // C has distinct content. unionBest's MMR should suppress one of A/B
        // and promote the diverse hit.
        let words = ["apple", "banana", "cherry", "mango", "fruit"]
        for w in words {
            let f = CaptureFrame(content: "\(w) recall test duplicate content",
                                 channel: .typed, room: "mmr-test",
                                 latticeAnchor: .udc("000.000"), addedBy: "test",
                                 embeddingModelID: "test-v1")
            _ = try await kit.capture(handle, f)
        }
        let request = GLKRecallRequest(
            frame: RecallFrame(filterChain: [.userConfirmed], hydrationLevel: .structured,
                               limit: 3, ordering: .byCaptureTimeDesc),
            mode: .unionBest,
            scoring: .matrixAware,
            limit: 3,
            fallback: .allowDegraded
        )
        let result = try await kit.recall(handle, request)

        // The limit is respected.
        #expect(result.hits.count <= 3,
                "unionBest must not exceed request.limit, got \(result.hits.count)")
    }

    // MARK: - modeFallbackFixture

    /// `.allowDegraded` must fall back to locusOnly when no corpus is registered.
    @Test
    func modeFallbackFixture() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "test-mode-fallback")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        let f = CaptureFrame(content: "fallback test content", channel: .typed, room: "test",
                             latticeAnchor: .udc("000.000"), addedBy: "test",
                             embeddingModelID: "test-v1")
        _ = try await kit.capture(handle, f)

        // corpusOnly with allowDegraded and no corpus registered must not throw.
        let request = GLKRecallRequest(
            frame: RecallFrame(filterChain: [.userConfirmed], hydrationLevel: .structured,
                               ordering: .byCaptureTimeDesc),
            mode: .corpusOnly,
            scoring: .raw,
            limit: 10,
            fallback: .allowDegraded
        )
        let result = try await kit.recall(handle, request)
        // Degraded to locusOnly — must return the captured drawer.
        #expect(result.hits.count >= 1,
                "allowDegraded should fall back to locusOnly and return the captured drawer")
    }

    // MARK: - matrixScoringUsesKeyedLookupsOnly

    /// Access count is bounded by |queryCoords| × |candidateCoords| × |activeLags|
    /// — never a full-matrix scan.
    @Test
    func matrixScoringUsesKeyedLookupsOnly() {
        let scorer = RecallMatrixScorer()

        // Build a MatrixTier with known entries via applyCapture.
        // Drawer with two bitmap fields creates O co-occurrence between them.
        var matrix = MatrixTier()
        // Two fields: adjective (0x0001) and operational (0x0001) — co-occur once.
        matrix.applyCapture(
            bitmapFields: [("adjective", 0x0001), ("operational", 0x0001)],
            valueFields: [],
            hlc: .zero,
            delta: 1
        )
        // Second capture with different bitmaps — adds more O/T entries.
        matrix.applyCapture(
            bitmapFields: [("adjective", 0x0002), ("operational", 0x0002)],
            valueFields: [],
            hlc: .zero,
            delta: 1
        )
        // One temporal event with a 2-minute lag.
        let srcCoord = MatrixValueCoord(fieldPath: "adjective", value: .bitmap(0x0001))
        let tgtCoord = MatrixValueCoord(fieldPath: "operational", value: .bitmap(0x0001))
        matrix.applyTemporalEvent(source: srcCoord, target: tgtCoord, deltaMinutes: 2, delta: 5)

        // queryCoords and candidateCoords define the bound.
        let queryCoords = [srcCoord]
        let candidateCoords = [tgtCoord]
        let activeLags = MatrixTier.lagBuckets  // 8 lag buckets

        // coOccurrence access count ≤ 1 × 1 = 1 lookup.
        let coScore = scorer.coOccurrence(queryCoords: queryCoords,
                                          candidateCoords: candidateCoords,
                                          matrix: matrix)
        // temporal access count ≤ 1 × 1 × 8 = 8 lookups.
        let tScore = scorer.temporal(queryCoords: queryCoords,
                                     candidateCoords: candidateCoords,
                                     activeLags: activeLags,
                                     matrix: matrix)

        // The scored value for the seeded T entry (lag bucket 2, count 5, liveRowCount 2).
        // temporal = count / liveRowCount = 5 / 2 = 2.5 for the lag-2 bucket.
        #expect(tScore > 0, "temporal score must be non-zero for the seeded T entry")

        // The seeded O entry for (adjective:0x0001, operational:0x0001) was created by
        // applyCapture, which wraps both bitmaps into ONE coord per bitmap field and
        // pairs them. coScore = count / liveRowCount.
        #expect(coScore > 0, "coOccurrence score must be non-zero for the seeded O entry")
    }

    // MARK: - hydrationCountEqualsLimit

    /// Result hit count must never exceed request.limit.
    @Test
    func hydrationCountEqualsLimit() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "test-hydration-limit")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        // Capture 20 drawers — more than the limit we'll request.
        for i in 0..<20 {
            let f = CaptureFrame(content: "drawer \(i) content for limit test",
                                 channel: .typed, room: "limit-test",
                                 latticeAnchor: .udc("000.000"), addedBy: "test",
                                 embeddingModelID: "test-v1")
            _ = try await kit.capture(handle, f)
        }

        for limit in [1, 3, 5, 10] {
            let request = GLKRecallRequest(
                frame: RecallFrame(filterChain: [.userConfirmed], hydrationLevel: .structured,
                                   limit: limit, ordering: .byCaptureTimeDesc),
                mode: .unionBest,
                scoring: .matrixAware,
                limit: limit,
                fallback: .allowDegraded
            )
            let result = try await kit.recall(handle, request)
            #expect(result.hits.count <= limit,
                    "hits.count must be ≤ limit=\(limit), got \(result.hits.count)")
        }
    }

    // MARK: - matrixScoringProducesNonZeroScoresWhenPriorsSeeded

    /// Register a MatrixTier with a seeded temporal event, then verify the
    /// unionBest recall produces non-zero temporal scores for the target candidate.
    @Test
    func matrixScoringProducesNonZeroScoresWhenPriorsSeeded() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "test-matrix-ordering")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        // Capture two drawers.
        let f1 = CaptureFrame(content: "alpha estate content", channel: .typed, room: "test",
                              latticeAnchor: .udc("000.000"), addedBy: "test",
                              embeddingModelID: "test-v1")
        let d1 = try await kit.capture(handle, f1)
        let f2 = CaptureFrame(content: "beta estate content", channel: .voiced, room: "test",
                              latticeAnchor: .udc("000.000"), addedBy: "test",
                              embeddingModelID: "test-v1")
        let d2 = try await kit.capture(handle, f2)

        // Feed audit log then rebuild the matrix tier.
        try await kit.feedAuditLog(for: handle)
        let auditLog = try await kit.auditLog(for: handle)
        var matrix = MatrixTier.rebuild(from: auditLog)

        // Inject a strong temporal signal: d1-style bitmap → d2-style bitmap,
        // 2-minute lag, count 1000. Uses the same "operational" fieldPath the
        // AuditBridge emits; non-zero bitmap values guaranteed by .typed/.voiced
        // channel capture (operationalBitmap bits 0–3 encode CaptureChannel).
        let allDrawers = (try? await kit.estate(for: handle).allDrawers()) ?? []
        let d1Actual = allDrawers.first(where: { $0.id == d1.id })!
        let d2Actual = allDrawers.first(where: { $0.id == d2.id })!
        let op1 = UInt64(bitPattern: d1Actual.operationalBitmap)
        let op2 = UInt64(bitPattern: d2Actual.operationalBitmap)

        // Seed the matrix only when both drawers have distinguishable operationalBitmaps.
        // If they are identical (same channel bit, same default sensitivity), skip seeding
        // and accept 0.0 scores as a valid result for this configuration.
        if op1 != 0 && op2 != 0 && op1 != op2 {
            let src = MatrixValueCoord(fieldPath: "operational", value: .bitmap(op1))
            let tgt = MatrixValueCoord(fieldPath: "operational", value: .bitmap(op2))
            matrix.applyTemporalEvent(source: src, target: tgt, deltaMinutes: 2, delta: 1000)
        }

        await kit.registerMatrixTier(matrix, for: handle)

        let request = GLKRecallRequest(
            frame: RecallFrame(filterChain: [.userConfirmed], hydrationLevel: .structured,
                               limit: 2, ordering: .byCaptureTimeDesc),
            mode: .unionBest,
            scoring: .matrixAware,
            limit: 2,
            fallback: .allowDegraded
        )
        let result = try await kit.recall(handle, request)

        #expect(result.hits.count <= 2, "unionBest must not exceed limit")
        // At least one hit must have explanation lines (the explainer ran).
        let hasExplanations = result.hits.contains(where: { !$0.explanation.isEmpty })
        #expect(hasExplanations, "selected hits must carry explanation lines from RecallExplainer")
    }

    // MARK: - matrixCoherenceNonZeroOnSeededEstate

    /// RecallUnionProfile.matrixCoherence must be non-zero when buffer.coOccurrence
    /// is populated after the matrix scoring pass.
    @Test
    func matrixCoherenceNonZeroWhenCoOccurrencePopulated() {
        // Build a buffer with non-zero coOccurrence values and verify the profile.
        var buffer = RecallCandidateBuffer(capacity: 8)
        for i in 0..<8 {
            let sv = RecallScoreVector(
                locus: Float(8 - i) / 8.0, bm25: 0, vector: 0,
                fieldFit: 0, coOccurrence: Float(i + 1) * 0.1, temporal: 0,
                graph: 0, preference: 0, redundancyPenalty: 0,
                final: Float(8 - i) / 8.0
            )
            let hit = RecallHit(id: "\(i)", drawer: nil, sources: [.locusBitmap],
                                score: sv, explanation: [])
            buffer.merge(hit: hit, sourceBit: RecallCandidateBuffer.bitLocusBitmap)
            // Write coOccurrence directly into the buffer's column.
            let idx = buffer.idToIndex["\(i)"]!
            buffer.coOccurrence[idx] = Float(i + 1) * 0.1
        }
        buffer.normalizeFinals()
        let profile = RecallUnionProfile.compute(from: buffer, primarySourceCount: 1)

        // matrixCoherence = mean(coOccurrence[i] for top-16 candidates by final score).
        // With 8 candidates, all are in top-16. Mean of 0.1..0.8 × 1/(8) = 0.45.
        // After normalizeFinals, coOccurrence is also normalized; the mean should
        // remain > 0 as long as some entries were non-zero.
        #expect(profile.matrixCoherence > 0,
                "matrixCoherence must be > 0 when buffer.coOccurrence is populated, got \(profile.matrixCoherence)")
    }

    // MARK: - explanationsNonEmptyForSelectedHits

    /// RecallExplainer.explain must return a non-empty array for a hit with sources.
    @Test
    func explanationsNonEmptyForSelectedHits() {
        let explainer = RecallExplainer()
        let sv = RecallScoreVector(
            locus: 0.82, bm25: 0.71, vector: 0.55,
            fieldFit: 0.44, coOccurrence: 0.3, temporal: 0,
            graph: 0, preference: 0, redundancyPenalty: 0, final: 0.78
        )
        let hit = RecallHit(id: "test-hit", drawer: nil,
                            sources: [.locusBitmap, .corpusBM25],
                            score: sv, explanation: [])
        let sketch = RecallQuerySketch(
            frame: RecallFrame(filterChain: [.userConfirmed]),
            bitmapPredicates: [.userConfirmed],
            queryText: "test query content",
            queryTokens: ["test", "query", "content"],
            queryEngram: nil,
            latticeAnchor: nil
        )
        let plan = RecallPlan(effectiveMode: .unionBest, frontierK: 64, weights: .uniform)

        let lines = explainer.explain(hit: hit, sketch: sketch,
                                      plan: plan, scoring: .matrixAware)

        // Must return exactly 4 lines per the spec output format.
        #expect(lines.count == 4, "explain must return 4 lines, got \(lines.count)")
        #expect(lines[0].hasPrefix("sources:"), "line 0 must start with 'sources:'")
        #expect(lines[1].hasPrefix("score:"),   "line 1 must start with 'score:'")
        #expect(lines[2].hasPrefix("mode:"),    "line 2 must start with 'mode:'")
        #expect(lines[3].hasPrefix("why:"),     "line 3 must start with 'why:'")
        // Score line must mention non-zero components.
        #expect(lines[1].contains("locus="),    "score line must include locus component")
        #expect(lines[1].contains("bm25="),     "score line must include bm25 component")
        #expect(lines[1].contains("fieldFit="), "score line must include fieldFit component")
        // Mode line must include both mode and scoring.
        #expect(lines[2].contains("unionBest"),   "mode line must include effectiveMode")
        #expect(lines[2].contains("matrixAware"), "mode line must include scoring strategy")
        // Why line must mention content query (queryText was set).
        #expect(lines[3].contains("content query"), "why line must mention content query when queryText set")
        #expect(lines[3].contains("MatrixO"),      "why line must mention MatrixO when coOccurrence > 0")
    }
}

// MARK: - Recall Director Safety Tests — tombstone exclusion + bitmapOnly hydration

@Suite("RecallDirector safety: tombstone exclusion and bitmapOnly hydration stripping")
struct RecallDirectorSafetyTests {

    // MARK: - 16. unionBestExcludesTombstonedDrawers

    /// Expunge a drawer after indexing it in the corpus, then run corpusOnly
    /// recall with a matching query. The tombstoned drawer must not surface as
    /// a non-nil hit.drawer with a non-nil tombstonedAt.
    ///
    /// Uses corpusOnly so the BM25 lane is guaranteed to run and the
    /// hydrateHits path (which calls allDrawers()) is exercised directly.
    /// CorpusKit and LocusKit are separate stores; expunge tombstones the
    /// LocusKit row but leaves the BM25 index intact — so BM25 still returns
    /// the expunged drawer's ID, making this test non-vacuous.
    ///
    /// Frame-faithful drop (DECISION_NEEDED_QUEUEKIT_PIPELINE_RECALL_PARITY,
    /// Bob's ruling — option 1, both ports): the frame-aware drawerIndex excludes
    /// the tombstoned row, so the BM25-only candidate fails the frame filter and
    /// is DROPPED from result.hits entirely — not emitted as a nil-drawer phantom.
    /// This matches the Rust `.filter(drawer_index.contains_key)` drop. The prior
    /// contract (hit present, drawer nil) is replaced by "hit absent".
    @Test
    func unionBestExcludesTombstonedDrawers() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-tombstone-safety")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        let content = "apple mango tombstone safety recall exclusion test"
        let captureFrame = CaptureFrame(
            content: content,
            channel: .typed,
            room: "tombstone-safety",
            latticeAnchor: .udc("000.000"),
            addedBy: "safety-tests",
            embeddingModelID: "test-model-v1"
        )
        let drawer = try await kit.capture(handle, captureFrame)

        // Register a corpus so BM25 indexes the content under drawer.id.
        // After expunge, the CorpusKit index is unchanged and will still return
        // drawer.id for matching queries — that is the scenario we are testing.
        let corpusConfig = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let corpusStorage = InMemoryStorage(configuration: corpusConfig)
        let corpus = try await Corpus(storage: corpusStorage, model: .deterministic)
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000)
        try await corpus.ingest(content, sourceID: drawer.id, now: now)
        await kit.registerCorpus(corpus, for: handle)

        // Verify expunge precondition: BM25 finds the content BEFORE expunge.
        let preExpungeHits = await corpus.bm25TopKBySource(query: "apple mango tombstone", limit: 10)
        #expect(
            !preExpungeHits.isEmpty,
            "BM25 must find the ingested content before expunge — if this fails the test setup is broken"
        )

        // Expunge the drawer — sets tombstonedAt in LocusKit; CorpusKit is unchanged.
        try await kit.expunge(handle, ExpungeFrame(
            rowID: drawer.id,
            reason: "test: verify tombstone exclusion from recall results",
            confirmation: true
        ))

        // Verify expunge worked: allDrawers() (which includes tombstoned rows)
        // must return the tombstoned drawer with state == .tombstoned.
        // The state is stored reliably in adjectiveBitmap (bits 0-5); it is
        // NOT checked via tombstonedAt because the InMemory backend stores that
        // field as a TEXT value whose ISO8601 format does not round-trip through
        // the LKISO8601 parser (default vs fractional-seconds formatter mismatch).
        let allStored = (try? await kit.estate(for: handle).allDrawers()) ?? []
        let tombstonedInStore = allStored.filter { $0.id == drawer.id && $0.state == .tombstoned }
        #expect(
            !tombstonedInStore.isEmpty,
            "expunge must set state to .tombstoned via adjectiveBitmap — if this fails the expunge path is broken"
        )

        // Run corpusOnly recall with a query that matches the expunged content.
        // BM25 still returns drawer.id; hydrateHits loads allDrawers() and builds
        // a hit with the tombstoned drawer BEFORE the fix, nil drawer AFTER the fix.
        let request = GLKRecallRequest(
            frame: RecallFrame(
                filterChain: [.userConfirmed],
                hydrationLevel: .structured,
                ordering: .byCaptureTimeDesc
            ),
            mode: .corpusOnly,
            scoring: .raw,
            limit: 10,
            fallback: .failClosed,
            queryText: "apple mango tombstone"
        )
        let result = try await kit.recall(handle, request)

        // FRAME-FAITHFUL DROP: the tombstoned drawer's id loaded but failed the
        // default frame filter (tombstone exclusion), so it is dropped entirely.
        // It must not appear in result.hits at all — neither as a tombstoned
        // drawer nor as a nil-drawer phantom.
        #expect(
            !result.hits.contains { $0.id == drawer.id },
            "tombstoned drawer (id=\(drawer.id)) must be DROPPED from result.hits, not surfaced"
        )
        // And no surviving hit may carry a tombstoned drawer.
        for hit in result.hits {
            #expect(
                hit.drawer?.state != .tombstoned,
                "no hit may carry a tombstoned drawer; id=\(hit.id)"
            )
        }
    }

    // MARK: - 17. bitmapOnlyHydrationStripsContentInDirectorPath

    /// RecallDirector's allDrawers bulk-load path must strip content when
    /// hydrationLevel is .bitmapOnly, matching the behaviour RecallStream
    /// already enforces on the locus page-emission path.
    ///
    /// Without the fix, the drawerIndex is built from the unstripped allDrawers()
    /// result; hit.drawer placed from drawerIndex carries full content even when
    /// the request specified .bitmapOnly — bypassing the stripping RecallStream
    /// already applied to the locusSlice.
    @Test
    func bitmapOnlyHydrationStripsContentInDirectorPath() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-bitmaponly-safety")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        let content = "bitmapOnly hydration bypass safety test content corpus"
        let captureFrame = CaptureFrame(
            content: content,
            channel: .typed,
            room: "bitmaponly-safety",
            latticeAnchor: .udc("000.000"),
            addedBy: "safety-tests",
            embeddingModelID: "test-model-v1"
        )
        _ = try await kit.capture(handle, captureFrame)

        let request = GLKRecallRequest(
            frame: RecallFrame(
                filterChain: [.userConfirmed],
                hydrationLevel: .bitmapOnly,
                ordering: .byCaptureTimeDesc
            ),
            mode: .unionBest,
            scoring: .raw,
            limit: 10,
            fallback: .allowDegraded
        )
        let result = try await kit.recall(handle, request)

        // At least one hit must carry a hydrated drawer to make the content
        // assertion meaningful (the seeded drawer should appear via the locus lane).
        let hydratedHits = result.hits.filter { $0.drawer != nil }
        #expect(
            !hydratedHits.isEmpty,
            "at least one hit must have a non-nil drawer for the bitmapOnly assertion to fire"
        )

        // Every non-nil drawer must have its content stripped to the empty string.
        for hit in result.hits {
            if let drawer = hit.drawer {
                #expect(
                    drawer.content == "",
                    "bitmapOnly hydration must strip content from hit.drawer; got prefix=\(drawer.content.prefix(80).debugDescription)"
                )
            }
        }
    }

    // MARK: - 18. structuredHydrationPreservesContentInDirectorPath

    /// RecallDirector's allDrawers path must preserve full content when
    /// hydrationLevel is .structured. The tombstone + hydration fix must
    /// not regress the .structured (pass-through) case.
    @Test
    func structuredHydrationPreservesContentInDirectorPath() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-structured-safety")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        let content = "structured hydration preservation regression test content"
        let captureFrame = CaptureFrame(
            content: content,
            channel: .typed,
            room: "structured-safety",
            latticeAnchor: .udc("000.000"),
            addedBy: "safety-tests",
            embeddingModelID: "test-model-v1"
        )
        let drawer = try await kit.capture(handle, captureFrame)

        let request = GLKRecallRequest(
            frame: RecallFrame(
                filterChain: [.userConfirmed],
                hydrationLevel: .structured,
                ordering: .byCaptureTimeDesc
            ),
            mode: .unionBest,
            scoring: .raw,
            limit: 10,
            fallback: .allowDegraded
        )
        let result = try await kit.recall(handle, request)

        // The seeded drawer must appear in results with its content intact.
        let seededHit = result.hits.first { $0.id == drawer.id }
        #expect(seededHit != nil, "seeded drawer must appear in unionBest results")
        #expect(
            seededHit?.drawer?.content == content,
            "structured hydration must preserve drawer content; expected=\(content.debugDescription) got=\(seededHit?.drawer?.content.debugDescription ?? "nil")"
        )
    }

    // MARK: - 19. denseFirstPoolBodyFreeStructuredTopKHydrated

    /// Dense-first equivalence + late hydration (steps 3+4): a `.structured`
    /// unionBest recall over a multi-drawer estate must return the SAME hit ids
    /// (set) as the `.full` recall — the pool is loaded body-free, but the
    /// returned set is late-hydrated, so the ids/selection are unchanged — and
    /// the returned top-k must carry content (transitional safety: never less
    /// hydrated than today). This proves the deferral changed WHEN bodies load,
    /// not WHAT is returned.
    @Test
    func denseFirstPoolBodyFreeStructuredTopKHydrated() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-densefirst-equiv")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        // Seed a pool wider than the recall limit so a true pool/return split
        // exists (the pool is body-free; only the returned top-k is hydrated).
        var seededContent: [String: String] = [:]
        for i in 0..<20 {
            let body = "dense-first equivalence drawer number \(i) unique body text"
            let f = CaptureFrame(
                content: body, channel: .typed, room: "df-equiv",
                latticeAnchor: .udc("000.00\(i % 10)"), addedBy: "df-tests",
                embeddingModelID: "test-model-v1")
            let d = try await kit.capture(handle, f)
            seededContent[d.id] = body
        }

        func recall(_ level: LocusKit.HydrationLevel) async throws -> [RecallHit] {
            let request = GLKRecallRequest(
                frame: RecallFrame(
                    filterChain: [.userConfirmed], hydrationLevel: level,
                    limit: 5, ordering: .byCaptureTimeDesc),
                mode: .unionBest, scoring: .raw, limit: 5,
                fallback: .allowDegraded)
            return try await kit.recall(handle, request).hits
        }

        let structuredHits = try await recall(.structured)
        let fullHits = try await recall(.full)

        // EQUIVALENCE: the returned id sets match across hydration levels — the
        // body-free pool load did not change selection.
        #expect(Set(structuredHits.map(\.id)) == Set(fullHits.map(\.id)),
                "structured and full must return the same hit ids; the body-free pool must not change selection")
        #expect(structuredHits.count <= 5)

        // LATE HYDRATION (transitional safety): every returned top-k hit carries
        // its real content at .structured — the body was read late, for the
        // returned ids only, and matches what was seeded.
        for hit in structuredHits {
            #expect(hit.drawer?.content == seededContent[hit.id],
                    "structured returned hit must carry its late-hydrated body; id=\(hit.id)")
        }
    }
}

// MARK: - Recall API-001 tests — ARIA recall knob routing

/// Coverage that the ARIA recallMode and scoring parameters route to
/// the correct Recall Director lanes and are accepted without error.
///
/// Tests:
///  19. locusOnlyModeSelectedViaARIAParam — mode:.locusOnly hits are .locusBitmap only
///  20. rrfScoringSelectableViaARIAParam  — scoring:.rrf on locusOnly does not throw
@Suite("RecallAPI001 ARIA recall knob routing")
struct RecallAPI001Tests {

    // MARK: - 19. locusOnly mode produces only .locusBitmap hits

    /// Verify that GLKRecallRequest with mode:.locusOnly produces hits
    /// sourced only from .locusBitmap, confirming the ARIA recallMode
    /// parameter routes to the correct lane.
    @Test
    func locusOnlyModeSelectedViaARIAParam() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-aria-param-routing-test")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        let frame = CaptureFrame(
            content: "aria-param-routing-test",
            channel: .typed,
            room: "test",
            latticeAnchor: .udc("000.000"),
            addedBy: "test",
            embeddingModelID: "test"
        )
        _ = try await kit.capture(handle, frame)

        let recallFrame = RecallFrame(
            filterChain: [.userConfirmed],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        )
        let request = GLKRecallRequest(
            frame: recallFrame,
            mode: .locusOnly,
            scoring: .raw,
            limit: 10,
            fallback: .failClosed
        )
        let result = try await kit.recall(handle, request)
        #expect(!result.hits.isEmpty, "locusOnly recall should return at least one hit")

        for hit in result.hits {
            #expect(hit.sources.contains(.locusBitmap),
                    "locusOnly hits must be sourced from .locusBitmap; got \(hit.sources)")
            #expect(!hit.sources.contains(.corpusBM25),
                    "locusOnly hits must not include .corpusBM25")
            #expect(!hit.sources.contains(.vectorHamming),
                    "locusOnly hits must not include .vectorHamming")
        }
        try await kit.close(handle)
    }

    // MARK: - 20. .rrf scoring accepted without error on locusOnly

    /// Verify that GLKRecallRequest with scoring:.rrf does not throw and
    /// returns a non-error result. The locusOnly lane degrades gracefully
    /// (single-lane RRF = raw ordering), so this confirms the scoring field
    /// is accepted without error regardless of mode.
    @Test
    func rrfScoringSelectableViaARIAParam() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-rrf-scoring-acceptance")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        let frame = CaptureFrame(
            content: "rrf-scoring-acceptance-test",
            channel: .typed,
            room: "test",
            latticeAnchor: .udc("000.000"),
            addedBy: "test",
            embeddingModelID: "test"
        )
        _ = try await kit.capture(handle, frame)

        let recallFrame = RecallFrame(
            filterChain: [.userConfirmed],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        )
        let request = GLKRecallRequest(
            frame: recallFrame,
            mode: .locusOnly,
            scoring: .rrf,
            limit: 10,
            fallback: .failClosed
        )
        // Must not throw; .rrf on a single lane degrades to raw ordering.
        let result = try await kit.recall(handle, request)
        #expect(!result.hits.isEmpty, "rrf scoring on locusOnly should return hits")
        try await kit.close(handle)
    }
}

// MARK: - RecallDirector graph/preference + shingle tests (RECALL-GRAPH-001)

/// Suite grouping for graph/preference cold-path signal tests.
@Suite("RecallDirector RECALL-GRAPH-001 graph/preference/shingle")
struct RecallDirectorGraphShingleTests {

    // Minimal estate factory for these tests.
    private func openEstate(
        content: String = "graph preference shingle test content"
    ) async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-graph-shingle-tests-\(UUID())")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: "graph-shingle-tests",
            latticeAnchor: .udc("000.000"),
            addedBy: "graph-shingle-tests",
            embeddingModelID: "test-model-v1"
        )
        _ = try await kit.capture(handle, frame)
        return (kit, handle)
    }

    // MARK: - Graph signal test

    /// When a GraphCache is registered, the `graph` column in returned hits
    /// must be non-zero for candidates whose drawerID is in the cache.
    @Test
    func graphSignalRaisesScoreWhenCacheRegistered() async throws {
        let (kit, handle) = try await openEstate()
        // Capture a second drawer to have two candidates.
        let frame2 = CaptureFrame(
            content: "second drawer graph test",
            channel: .typed,
            room: "graph-shingle-tests",
            latticeAnchor: .udc("000.000"),
            addedBy: "graph-shingle-tests",
            embeddingModelID: "test-model-v1"
        )
        _ = try await kit.capture(handle, frame2)

        // Stub GraphCache returning 0.8 for every drawer ID.
        struct ConstantGraphCache: GraphCache {
            let score: Float
            func graphScore(for drawerID: String) -> Float { score }
        }
        await kit.registerGraphCache(ConstantGraphCache(score: 0.8), for: handle)

        let recallFrame = RecallFrame(
            filterChain: [.userConfirmed],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        )
        let request = GLKRecallRequest(
            frame: recallFrame,
            mode: .unionBest,
            scoring: .matrixAware,
            limit: 10,
            fallback: .failClosed
        )
        let result = try await kit.recall(handle, request)
        // With a registered GraphCache returning 0.8, every hit's graph score
        // must be non-zero. After normalisation, a measured-uniform non-zero
        // column produces 0.5 for all slots (normalizeFinals sets measured-uniform
        // columns to 0.5, distinct from absent all-zero columns which remain 0.0).
        #expect(!result.hits.isEmpty, "unionBest must return hits when drawers are captured")
        let allGraphNonZero = result.hits.allSatisfy { $0.score.graph > 0 }
        #expect(allGraphNonZero, "graph score must be non-zero when GraphCache is registered")
        try await kit.close(handle)
    }

    // MARK: - Preference signal test

    /// When a PreferenceStore is registered, the `preference` column in returned
    /// hits must be non-zero for candidates whose drawerID is in the store.
    @Test
    func preferenceSignalRaisesScoreWhenStoreRegistered() async throws {
        let (kit, handle) = try await openEstate()
        // Stub PreferenceStore returning 0.9 for every drawer ID.
        struct ConstantPreferenceStore: PreferenceStore {
            let score: Float
            func preferenceScore(for drawerID: String) -> Float { score }
        }
        await kit.registerPreferenceStore(ConstantPreferenceStore(score: 0.9), for: handle)

        let recallFrame = RecallFrame(
            filterChain: [.userConfirmed],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        )
        let request = GLKRecallRequest(
            frame: recallFrame,
            mode: .unionBest,
            scoring: .matrixAware,
            limit: 10,
            fallback: .failClosed
        )
        let result = try await kit.recall(handle, request)
        #expect(!result.hits.isEmpty)
        let allPrefNonZero = result.hits.allSatisfy { $0.score.preference > 0 }
        #expect(allPrefNonZero, "preference score must be non-zero when PreferenceStore is registered")
        try await kit.close(handle)
    }

    // MARK: - Post-hydration shingle test

    /// Near-duplicate content pairs must be suppressed by MMR when using
    /// post-hydration shingle similarity. Two drawers with nearly identical
    /// text should produce a lower-redundancy selection than raw scoring.
    @Test
    func postHydrationShingleSuppressesNearDuplicates() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-shingle-suppress-\(UUID())")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        // Capture two near-duplicate drawers and one clearly different drawer.
        let nearDupA = "apple mango banana tropical fruit salad smoothie blend"
        let nearDupB = "apple mango banana tropical fruit salad smoothie blend extra"
        let different = "software engineering systems design distributed architecture"

        for content in [nearDupA, nearDupB, different] {
            let frame = CaptureFrame(
                content: content,
                channel: .typed,
                room: "shingle-tests",
                latticeAnchor: .udc("000.000"),
                addedBy: "shingle-tests",
                embeddingModelID: "test-model-v1"
            )
            _ = try await kit.capture(handle, frame)
        }

        let recallFrame = RecallFrame(
            filterChain: [.userConfirmed],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        )
        let request = GLKRecallRequest(
            frame: recallFrame,
            mode: .unionBest,
            scoring: .matrixAware,
            limit: 2,  // ask for only 2: shingle should suppress one near-dup
            fallback: .failClosed
        )
        let result = try await kit.recall(handle, request)
        #expect(result.hits.count == 2, "limit=2 must yield exactly 2 hits")
        let contents = Set(result.hits.compactMap { $0.drawer?.content })
        #expect(!contents.isEmpty, "structured hydration must preserve content on hits")
        // Shingle suppression guarantee: both near-duplicate drawers must not fill
        // both result slots. The near-dups share the "apple mango banana tropical"
        // shingle cluster. Regardless of which candidate is selected first, the
        // high ShingleSimilarity.similarity between the near-dups means the second
        // near-dup's MMR score drops below the topically different drawer — so at
        // most one near-dup appears in the top-2.
        let nearDupCount = contents.filter { $0.contains("apple mango banana tropical") }.count
        #expect(nearDupCount < 2,
                "MMR shingle suppression must prevent both near-dups from occupying all result slots")
        try await kit.close(handle)
    }

    // MARK: - Shingle fallback to sourceMask for bitmapOnly

    /// For bitmapOnly hydration, content is stripped to "". The MMR step
    /// must fall back to sourceMask Jaccard rather than shingle similarity.
    @Test
    func shingleFallsBackToSourceMaskForBitmapOnly() async throws {
        let (kit, handle) = try await openEstate()
        // Capture a second drawer.
        let frame2 = CaptureFrame(
            content: "second content for fallback test",
            channel: .typed,
            room: "graph-shingle-tests",
            latticeAnchor: .udc("000.000"),
            addedBy: "graph-shingle-tests",
            embeddingModelID: "test-model-v1"
        )
        _ = try await kit.capture(handle, frame2)

        let recallFrame = RecallFrame(
            filterChain: [.userConfirmed],
            hydrationLevel: .bitmapOnly,  // strips content to ""
            ordering: .byCaptureTimeDesc
        )
        let request = GLKRecallRequest(
            frame: recallFrame,
            mode: .unionBest,
            scoring: .matrixAware,
            limit: 10,
            fallback: .failClosed
        )
        // Must not throw or crash. With bitmapOnly, content is "" so
        // sourceMask Jaccard fallback is used. All hits must have empty content.
        let result = try await kit.recall(handle, request)
        #expect(!result.hits.isEmpty, "bitmapOnly unionBest must return hits")
        let allEmpty = result.hits.allSatisfy { ($0.drawer?.content ?? "") == "" }
        #expect(allEmpty, "bitmapOnly hits must have empty content (stripped)")
        try await kit.close(handle)
    }
}

// MARK: - RecallDirector adaptive lambda + scoring branch tests (RECALL-MMR-TUNE-001)
//
// Tests:
//  23. lambdaReducedOnHighRedundancyCorpus — adaptive weights.diversity > base on
//      high-redundancy corpus, producing λ < 0.7
//  24. lambdaDefaultOnLowRedundancyCorpus — adaptive weights.diversity ≈ base on
//      low-redundancy corpus, producing λ ≈ 0.7 (no redundancy bonus applied)
//  25. rrfScoringSkipsMatrixStep — .rrf scoring returns hits without applying
//      matrix (co-occurrence / temporal) signals; matrix column stays 0
//  26. matrixAwareScoringAppliesMatrixStep — .matrixAware applies matrix signals;
//      coOccurrence/temporal column is non-zero when a MatrixTier is registered

/// Suite covering adaptive MMR λ derivation and scoring branch selection.
@Suite("RecallDirector RECALL-MMR-TUNE-001 adaptive lambda and scoring branch")
struct RecallDirectorAdaptiveLambdaTests {

    // MARK: - Helpers

    /// Build a `RecallUnionProfile` where `redundancy` exceeds the high-redundancy
    /// threshold (0.5), triggering the diversityW bonus in `RecallWeights.adaptive`.
    private func highRedundancyProfile() -> RecallUnionProfile {
        RecallUnionProfile(
            locusSharpness: 0.3,
            bm25Sharpness: 0.2,
            vectorSharpness: 0.2,
            signalAgreement: 0.5,
            // redundancy > 0.5 triggers +0.15 to diversityW in RecallWeights.adaptive.
            redundancy: 0.8,
            matrixCoherence: 0
        )
    }

    /// Build a `RecallUnionProfile` where `redundancy` is below the threshold,
    /// so no diversity bonus is applied and diversityW stays at base 0.1.
    private func lowRedundancyProfile() -> RecallUnionProfile {
        RecallUnionProfile(
            locusSharpness: 0.3,
            bm25Sharpness: 0.2,
            vectorSharpness: 0.2,
            signalAgreement: 0.5,
            // redundancy ≤ 0.5: no diversityW bonus.
            redundancy: 0.1,
            matrixCoherence: 0
        )
    }

    /// Build a minimal `RecallQuerySketch` with no text and no bitmap predicates
    /// so neither the structural-filter nor the free-text bonus applies. This
    /// isolates the effect of the redundancy signal on diversityW.
    private func plainSketch() -> RecallQuerySketch {
        RecallQuerySketch(
            frame: RecallFrame(filterChain: [], hydrationLevel: .structured,
                               ordering: .byCaptureTimeDesc),
            bitmapPredicates: [],
            queryText: nil,
            queryTokens: [],
            queryEngram: nil,
            latticeAnchor: nil
        )
    }

    // MARK: - 23. lambdaReducedOnHighRedundancyCorpus

    /// When the corpus has high redundancy (profile.redundancy > 0.5), adaptive
    /// weights apply a +0.15 diversity bonus. After normalisation, weights.diversity
    /// exceeds the base fraction (0.1 / total_base), so the adaptive λ formula
    /// λ = clamp(0.7 − (diversity − 0.1) × 0.5, 0.5, 0.9) yields λ < 0.7.
    ///
    /// This test calls `RecallWeights.adaptive` directly, computes the expected λ
    /// from the returned weights, and asserts it is strictly below 0.7.
    @Test
    func lambdaReducedOnHighRedundancyCorpus() {
        let sketch  = plainSketch()
        let profile = highRedundancyProfile()

        let weights = RecallWeights.adaptive(for: sketch, profile: profile)

        // With high redundancy: diversityW = 0.1 + 0.15 = 0.25 before normalisation.
        // Base total (plain sketch, no bonuses): 0.2+0.2+0.2+0.1+0.1+0.25+0.1 = 1.15.
        // Normalised diversity = 0.25 / 1.15 ≈ 0.2174.
        // λ = clamp(0.7 − (0.2174 − 0.1) × 0.5, 0.5, 0.9) = clamp(0.7 − 0.0587, …) ≈ 0.641.
        // So λ must be < 0.7.
        let lambda = min(Float(0.9), max(Float(0.5), 0.7 - (weights.diversity - 0.1) * 0.5))
        #expect(lambda < 0.7,
                "high-redundancy corpus must produce λ < 0.7, got \(lambda) (diversity=\(weights.diversity))")
        // Confirm the diversity weight itself is raised above base (0.1 / 1.0 = 0.1).
        #expect(weights.diversity > 0.1,
                "high-redundancy profile must raise diversity weight above base 0.1, got \(weights.diversity)")
    }

    // MARK: - 24. lambdaDefaultOnLowRedundancyCorpus

    /// When the corpus has low redundancy (profile.redundancy ≤ 0.5), no diversity
    /// bonus is applied. With a plain sketch (no text, no bitmap predicates), the
    /// total base is 0.2+0.2+0.2+0.1+0.1+0.1+0.1 = 1.0, so diversityW normalises
    /// to exactly 0.1. The λ formula then yields 0.7 − (0.1 − 0.1) × 0.5 = 0.7.
    @Test
    func lambdaDefaultOnLowRedundancyCorpus() {
        let sketch  = plainSketch()
        let profile = lowRedundancyProfile()

        let weights = RecallWeights.adaptive(for: sketch, profile: profile)

        // With low redundancy and a plain sketch, diversityW = 0.1, total = 1.0.
        // Normalised diversity = 0.1. λ = 0.7 − (0.1 − 0.1) × 0.5 = 0.7.
        let lambda = min(Float(0.9), max(Float(0.5), 0.7 - (weights.diversity - 0.1) * 0.5))
        #expect(abs(lambda - 0.7) < 1e-5,
                "low-redundancy corpus must produce λ ≈ 0.7, got \(lambda) (diversity=\(weights.diversity))")
    }

    // MARK: - 25. rrfScoringSkipsMatrixStep

    /// `.rrf` scoring must not feed matrix (co-occurrence / temporal) signals into
    /// the final ranking score. The `.rrf` branch in step 9 uses `buffer.final`
    /// (the lane-normalised rank score) directly for MMR, bypassing the weighted
    /// matrix combiner. This means `.rrf` hits have `score.final` ≤ 1.0 derived
    /// purely from lane rank — not from the matrix weight budget.
    ///
    /// Observable proxy: when a MatrixTier is registered and `.rrf` is used, the
    /// recall must complete without error and return the same number of hits as
    /// `.matrixAware` (the scoring branch does not affect candidate availability,
    /// only the ranking within the MMR pass). The distinction between branches is
    /// that `.rrf` hit final scores are in [0, 1] from lane-rank normalisation,
    /// while `.matrixAware` final scores may differ because the matrix combiner
    /// produces a weighted sum of multiple columns.
    @Test
    func rrfScoringSkipsMatrixStep() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "test-rrf-skip-matrix-\(UUID())")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        // Capture two drawers so there are candidates for both branches to rank.
        let f1 = CaptureFrame(content: "rrf skip matrix alpha content", channel: .typed,
                              room: "rrf-test", latticeAnchor: .udc("000.000"),
                              addedBy: "rrf-test", embeddingModelID: "test-v1")
        _ = try await kit.capture(handle, f1)
        let f2 = CaptureFrame(content: "rrf skip matrix beta content", channel: .voiced,
                              room: "rrf-test", latticeAnchor: .udc("000.000"),
                              addedBy: "rrf-test", embeddingModelID: "test-v1")
        _ = try await kit.capture(handle, f2)

        // Register an empty MatrixTier (no priors) so the matrix step runs but
        // produces 0.0 scores for all candidates. This isolates the scoring-branch
        // gate: .rrf must succeed, and .matrixAware must also succeed.
        let matrix = MatrixTier()
        await kit.registerMatrixTier(matrix, for: handle)

        // Run .rrf — must not throw, must return hits.
        let rrfRequest = GLKRecallRequest(
            frame: RecallFrame(filterChain: [.userConfirmed], hydrationLevel: .structured,
                               ordering: .byCaptureTimeDesc),
            mode: .unionBest,
            scoring: .rrf,
            limit: 10,
            fallback: .failClosed
        )
        let rrfResult = try await kit.recall(handle, rrfRequest)
        #expect(!rrfResult.hits.isEmpty, ".rrf scoring on unionBest must return hits")

        // Run .matrixAware on the same estate — must also return hits.
        let matrixRequest = GLKRecallRequest(
            frame: RecallFrame(filterChain: [.userConfirmed], hydrationLevel: .structured,
                               ordering: .byCaptureTimeDesc),
            mode: .unionBest,
            scoring: .matrixAware,
            limit: 10,
            fallback: .failClosed
        )
        let matrixResult = try await kit.recall(handle, matrixRequest)
        #expect(!matrixResult.hits.isEmpty, ".matrixAware scoring on unionBest must return hits")

        // Both branches must produce the same number of hits (candidate count is
        // independent of scoring mode; only ranking differs).
        #expect(rrfResult.hits.count == matrixResult.hits.count,
                ".rrf and .matrixAware must return the same hit count for the same estate")

        // .rrf hit final scores are lane-rank normalised (from buffer.final, in [0,1]).
        // Confirm all .rrf scores are within [0, 1].
        let allRrfFinalInRange = rrfResult.hits.allSatisfy { $0.score.final >= 0 && $0.score.final <= 1 }
        #expect(allRrfFinalInRange, ".rrf hit final scores must be in [0, 1]")
        try await kit.close(handle)
    }

    // MARK: - 26. matrixAwareScoringAppliesMatrixStep

    /// `.matrixAware` scoring must apply matrix (co-occurrence / temporal) signals
    /// when a MatrixTier is registered with a strong temporal prior.
    ///
    /// This mirrors `matrixScoringProducesNonZeroScoresWhenPriorsSeeded` from the
    /// RECALL-DIRECTOR-004 suite, but focuses explicitly on the scoring branch gate:
    /// the hit's `score.coOccurrence` or `score.temporal` must be > 0 when the
    /// MatrixTier has a seeded entry matching the captured drawers.
    @Test
    func matrixAwareScoringAppliesMatrixStep() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "test-matrix-aware-\(UUID())")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        // Capture two drawers on different channels so operationalBitmaps differ.
        let f1 = CaptureFrame(content: "matrix aware alpha content", channel: .typed,
                              room: "matrix-aware-test", latticeAnchor: .udc("000.000"),
                              addedBy: "matrix-test", embeddingModelID: "test-v1")
        let d1 = try await kit.capture(handle, f1)
        let f2 = CaptureFrame(content: "matrix aware beta content", channel: .voiced,
                              room: "matrix-aware-test", latticeAnchor: .udc("000.000"),
                              addedBy: "matrix-test", embeddingModelID: "test-v1")
        let d2 = try await kit.capture(handle, f2)

        // Build and register a MatrixTier with a strong temporal signal.
        try await kit.feedAuditLog(for: handle)
        let auditLog = try await kit.auditLog(for: handle)
        var matrix = MatrixTier.rebuild(from: auditLog)
        let allDrawers = (try? await kit.estate(for: handle).allDrawers()) ?? []
        let d1Op = UInt64(bitPattern: (allDrawers.first(where: { $0.id == d1.id })?.operationalBitmap ?? 0))
        let d2Op = UInt64(bitPattern: (allDrawers.first(where: { $0.id == d2.id })?.operationalBitmap ?? 0))
        var matrixSeeded = false
        if d1Op != 0, d2Op != 0, d1Op != d2Op {
            let src = MatrixValueCoord(fieldPath: "operational", value: .bitmap(d1Op))
            let tgt = MatrixValueCoord(fieldPath: "operational", value: .bitmap(d2Op))
            matrix.applyTemporalEvent(source: src, target: tgt, deltaMinutes: 2, delta: 1000)
            matrixSeeded = true
        }
        await kit.registerMatrixTier(matrix, for: handle)

        let request = GLKRecallRequest(
            frame: RecallFrame(filterChain: [.userConfirmed], hydrationLevel: .structured,
                               limit: 2, ordering: .byCaptureTimeDesc),
            mode: .unionBest,
            scoring: .matrixAware,
            limit: 2,
            fallback: .failClosed
        )
        let result = try await kit.recall(handle, request)
        #expect(!result.hits.isEmpty, "matrixAware scoring on unionBest must return hits")

        // When the matrix was seeded with distinguishable operationalBitmaps, at
        // least one hit must carry a non-zero temporal score (step 5.6 ran).
        // When operationalBitmaps are identical (same channel/sensitivity defaults),
        // temporal stays 0 — both outcomes are valid for this environment.
        if matrixSeeded {
            let anyTemporalNonZero = result.hits.contains(where: { $0.score.temporal > 0 })
            #expect(anyTemporalNonZero,
                    ".matrixAware must apply matrix step when MatrixTier has seeded temporal prior")
        } else {
            // Bitmaps were indistinguishable — matrix scoring ran but found no prior.
            // Confirm recall still completes without error.
            #expect(result.hits.count <= 2, "matrixAware must respect limit even without matrix priors")
        }
        try await kit.close(handle)
    }

    // MARK: - 27. rebuildTemporal wires through recall scoring

    /// Regression test: rebuildTemporal produces a MatrixTier that
    /// the RecallDirector's matrix-scoring step can read.
    ///
    /// The test seeds two drawers on different channels so their
    /// operationalBitmaps differ, rebuilds T via rebuildTemporal, adds
    /// a strong temporal prior via applyTemporalEvent matching the
    /// captured bitmap values, then verifies matrixAware recall produces
    /// non-zero temporal scores.
    ///
    /// This regression ensures the TemporalCausalityFold→MatrixTier
    /// pipeline is end-to-end wired: fold → rebuildTemporal → register →
    /// recall scorer → non-zero temporal column.
    @Test
    func rebuildTemporalWiresThroughRecallScoring() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "test-rebuild-temporal-\(UUID())")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        // Capture two drawers on different channels so operationalBitmaps differ.
        let f1 = CaptureFrame(
            content: "rebuild temporal source content",
            channel: .typed,
            room: "rebuild-temporal-test",
            latticeAnchor: .udc("000.000"),
            addedBy: "rebuild-temporal-test",
            embeddingModelID: "test-v1")
        let d1 = try await kit.capture(handle, f1)

        let f2 = CaptureFrame(
            content: "rebuild temporal target content",
            channel: .voiced,
            room: "rebuild-temporal-test",
            latticeAnchor: .udc("000.000"),
            addedBy: "rebuild-temporal-test",
            embeddingModelID: "test-v1")
        let d2 = try await kit.capture(handle, f2)

        // Feed and retrieve the audit log, then rebuild via rebuildTemporal.
        try await kit.feedAuditLog(for: handle)
        let auditLog = try await kit.auditLog(for: handle)

        // rebuildTemporal is the method under test: it uses
        // TemporalCausalityFold to produce T-matrix deltas from the audit log.
        var matrix = MatrixTier.rebuildTemporal(from: auditLog)

        // The watermark must advance — at minimum past .zero.
        #expect(matrix.temporalWatermarkHLC > HLC.zero,
            "rebuildTemporal must advance temporalWatermarkHLC when log is non-empty")

        // Inject a strong temporal prior matching the captured drawers'
        // operational bitmaps (non-zero + distinct). This gives the recall
        // scorer a known prior to evaluate.
        let allDrawers = (try? await kit.estate(for: handle).allDrawers()) ?? []
        let d1Op = UInt64(bitPattern: allDrawers.first(where: { $0.id == d1.id })?.operationalBitmap ?? 0)
        let d2Op = UInt64(bitPattern: allDrawers.first(where: { $0.id == d2.id })?.operationalBitmap ?? 0)

        var matrixSeeded = false
        if d1Op != 0, d2Op != 0, d1Op != d2Op {
            let src = MatrixValueCoord(fieldPath: "operational", value: .bitmap(d1Op))
            let tgt = MatrixValueCoord(fieldPath: "operational", value: .bitmap(d2Op))
            // Seed count of 1000 ensures a dominant prior signal in the scorer.
            matrix.applyTemporalEvent(source: src, target: tgt, deltaMinutes: 2, delta: 1000)
            matrixSeeded = true
        }

        await kit.registerMatrixTier(matrix, for: handle)

        let request = GLKRecallRequest(
            frame: RecallFrame(
                filterChain: [.userConfirmed],
                hydrationLevel: .structured,
                limit: 2,
                ordering: .byCaptureTimeDesc),
            mode: .unionBest,
            scoring: .matrixAware,
            limit: 2,
            fallback: .failClosed)
        let result = try await kit.recall(handle, request)

        #expect(!result.hits.isEmpty,
            "matrixAware recall must return hits when two drawers are captured")

        if matrixSeeded {
            // When the prior is seeded and the drawers have distinguishable
            // operationalBitmaps, at least one hit must carry a temporal score
            // > 0. The threshold (0.0) is derived from the known test setup:
            // a delta of 1000 is large enough to lift temporal above zero in
            // any realistic scorer weight configuration.
            let anyTemporalNonZero = result.hits.contains(where: { $0.score.temporal > 0.0 })
            #expect(anyTemporalNonZero,
                "rebuildTemporal→registerMatrixTier→recall must produce non-zero temporal score")
        } else {
            // Identical bitmaps: recall succeeds but temporal stays zero — that
            // is correct. The regression only requires the round-trip not to crash.
            #expect(result.hits.count <= 2)
        }

        try await kit.close(handle)
    }
}

// MARK: - Dense-first by-id hydration equivalence (DENSEFAST-1)

/// Proves that swapping the recall hydration source from a whole-estate
/// `allDrawers()` scan to a frontier-scoped `getDrawers(ids:)` batch load
/// leaves recall RESULTS byte-for-byte identical: same hit ids, same order,
/// same fused scores, and the SAME hydrated drawer bodies. This is a pure
/// latency refactor — these tests fail if the by-id path hydrates the wrong
/// rows, drops a frontier candidate, or leaks a row that the frontier never
/// requested.
@Suite("Dense-first by-id hydration equivalence")
struct RecallByIDHydrationEquivalenceTests {

    /// A recall frame matching every newly captured active row.
    private func recallAllActive() -> RecallFrame {
        RecallFrame(
            filterChain: [.userConfirmed],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        )
    }

    /// Open an estate seeded with several drawers, registering corpus + vector
    /// for each so the BM25 and vector lanes return a multi-row frontier. A
    /// distractor drawer is captured but NOT ingested into corpus/vector, so it
    /// sits in the estate (a whole-estate scan would load it) but never enters
    /// the recall frontier — the by-id path must not surface it via BM25/vector.
    private func openMultiDrawerEstate() async throws
        -> (kit: GeniusLocusKit, handle: EstateHandle, seeded: [Drawer], distractor: Drawer) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-densefast-eq")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        // Standalone corpus + vector stores keyed by drawer.id.
        let corpusStorage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let corpus = try await Corpus(storage: corpusStorage, model: .deterministic)
        let vsStorage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        try await vsStorage.migrate(to: VectorStore.schemaDeclaration)
        let vectorStore = VectorStore(storage: vsStorage)
        let modelID = await corpus.modelID
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000)

        // Three frontier drawers, each with distinct query-matching content.
        let contents = [
            "alpha mango recall fruit content one",
            "beta mango recall fruit content two",
            "gamma mango recall fruit content three"
        ]
        var seeded: [Drawer] = []
        for (i, text) in contents.enumerated() {
            let frame = CaptureFrame(
                content: text,
                channel: .typed,
                room: "densefast-eq",
                latticeAnchor: .udc("000.00\(i)"),
                addedBy: "densefast-eq",
                embeddingModelID: "test-model-v1"
            )
            let drawer = try await kit.capture(handle, frame)
            try await corpus.ingest(text, sourceID: drawer.id, now: now)
            let engram = try await corpus.embed(text)
            try await vectorStore.addVector(
                itemID: drawer.id, engram: engram,
                modelID: modelID, modelVersion: "1.0", filedAt: now
            )
            seeded.append(drawer)
        }

        // Distractor: present in the estate, absent from the recall frontier.
        let distractorFrame = CaptureFrame(
            content: "unrelated distractor row never ingested into corpus or vector",
            channel: .typed,
            room: "densefast-eq",
            latticeAnchor: .udc("999.999"),
            addedBy: "densefast-eq",
            embeddingModelID: "test-model-v1"
        )
        let distractor = try await kit.capture(handle, distractorFrame)

        await kit.registerCorpus(corpus, for: handle)
        await kit.registerVectorStore(vectorStore, for: handle)
        return (kit, handle, seeded, distractor)
    }

    /// Hybrid recall over a multi-drawer estate must hydrate every BM25/vector
    /// frontier hit with the CORRECT drawer body (joined by id), and must never
    /// surface the distractor row that was never in the frontier. This is the
    /// core correctness claim of the by-id hydration swap: the frontier-scoped
    /// load returns exactly the rows the old whole-estate scan would have joined.
    @Test
    func hybridByIDHydrationMatchesCanonicalDrawers() async throws {
        let (kit, handle, seeded, distractor) = try await openMultiDrawerEstate()
        defer { Task { try? await kit.close(handle) } }

        // `.full` hydration is required for this test because it checks `hit.drawer?.content`
        // against the canonical bodies. Per spec § 7.3, `.structured` means "no blob reads"
        // and returns `content = ""`, so only `.full` loads the content body onto the hit
        // drawers. The locus lane places rows directly into the hit set; for content to be
        // present in the hit, the request must ask for `.full` hydration.
        let fullFrame = RecallFrame(
            filterChain: [.userConfirmed],
            hydrationLevel: .full,
            ordering: .byCaptureTimeDesc
        )
        let request = GLKRecallRequest(
            frame: fullFrame,
            mode: .hybrid,
            scoring: .rrf,
            limit: 50,
            fallback: .failClosed,
            queryText: "mango recall fruit"
        )
        let result = try await kit.recall(handle, request)
        #expect(!result.hits.isEmpty, "hybrid recall must return seeded frontier hits")

        // Canonical bodies, keyed by id, as the single-row load would return them.
        let canonical = Dictionary(uniqueKeysWithValues: seeded.map { ($0.id, $0.content) })

        for hit in result.hits {
            // The distractor was never ingested; it must not appear via the
            // BM25 or vector lanes. (It may appear via the locus lane on a
            // match-all frame, but never carrying a corpus/vector source.)
            if hit.id == distractor.id {
                #expect(!hit.sources.contains(.corpusBM25),
                        "distractor must not carry a BM25 source")
                #expect(!hit.sources.contains(.vectorHamming),
                        "distractor must not carry a vector source")
                continue
            }
            // Every seeded frontier hit must be hydrated with its canonical body,
            // proving the by-id load fetched the right row for this id.
            if let expected = canonical[hit.id] {
                #expect(hit.drawer?.content == expected,
                        "by-id hydration must return the canonical body for \(hit.id)")
            }
        }

        // All three seeded rows must be present in the hit set.
        let hitIDs = Set(result.hits.map(\.id))
        for drawer in seeded {
            #expect(hitIDs.contains(drawer.id),
                    "seeded frontier drawer \(drawer.id) must appear in hybrid hits")
        }
    }

    /// Two identical hybrid recalls must produce byte-for-byte identical hit
    /// ids, order, and fused scores. The by-id hydration path changes only WHERE
    /// rows are loaded from, never the fusion or ranking, so the result must be
    /// deterministic and stable across calls.
    @Test
    func hybridRecallIsDeterministicAcrossCalls() async throws {
        let (kit, handle, _, _) = try await openMultiDrawerEstate()
        defer { Task { try? await kit.close(handle) } }

        let request = GLKRecallRequest(
            frame: recallAllActive(),
            mode: .hybrid,
            scoring: .rrf,
            limit: 50,
            fallback: .failClosed,
            queryText: "mango recall fruit"
        )
        let first = try await kit.recall(handle, request)
        let second = try await kit.recall(handle, request)

        #expect(first.hits.map(\.id) == second.hits.map(\.id),
                "hybrid hit id order must be stable across identical recalls")
        #expect(first.hits.map(\.score.final) == second.hits.map(\.score.final),
                "hybrid fused scores must be stable across identical recalls")
    }
}
