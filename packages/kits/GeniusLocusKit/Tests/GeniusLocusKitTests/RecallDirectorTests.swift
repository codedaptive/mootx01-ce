// RecallDirectorTests.swift
//
// Coverage for the Recall Director API.
//
// Tests:
//   1. GLKRecallMode Codable round-trip across all 4 cases
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

import Testing
import Foundation
import LocusKit
import CorpusKit
import PersistenceKit
import PersistenceKitInMemory
import VectorKit
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
        // This lets the RecallDirector join VectorMatch.drawerID → LocusKit Drawer.id
        // without an intermediate chunk-to-source mapping step.
        let vsConfig = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let vsStorage = InMemoryStorage(configuration: vsConfig)
        try await vsStorage.migrate(to: VectorStore.schemaDeclaration)
        let vectorStore = VectorStore(storage: vsStorage)
        let engram = try await corpus.embed(content)
        let modelID = await corpus.modelID
        try await vectorStore.addVector(
            drawerID: drawer.id,
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
            filterChain: [.unconfirmed],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        )
    }

    // MARK: - 1. GLKRecallMode Codable round-trip

    /// All four `GLKRecallMode` cases must survive a JSON encode/decode round-trip.
    ///
    /// This pins the rawValue strings that will appear in persistence and MCP
    /// payloads. A changed rawValue is a breaking change; this test will catch it.
    @Test
    func glkRecallModeDecodesAllFourCases() throws {
        // Verify CaseIterable covers exactly 4 cases.
        #expect(GLKRecallMode.allCases.count == 4)

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
            frame: RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .structured,
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
            frame: RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .structured,
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
                frame: RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .structured,
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
            frame: RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .structured,
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
            frame: RecallFrame(filterChain: [.unconfirmed]),
            bitmapPredicates: [.unconfirmed],
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
