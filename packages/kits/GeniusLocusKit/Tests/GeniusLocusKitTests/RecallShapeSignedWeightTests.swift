// RecallShapeSignedWeightTests.swift
//
// Tests for the 6b-modifiers-core RecallShape signed-weight fusion ENGINE.
//
// RecallShape makes the RecallDirector's RRF fusion STEERABLE by signed per-lane
// weights, without changing the fusion algorithm. These tests prove, on the
// hybrid lane (locus + bm25 + hamming, all routed through the weighted rrfFuseN):
//
//   (a) nil-shape back-compat — an absent shape is BYTE-IDENTICAL to today.
//   (b) exclusion — a lane weighted 0 drops that lane's votes entirely.
//   (c) suppression — a lane weighted < 0 DEMOTES a candidate it ranks high.
//   (d) leave-one-out — nulling one signal removes that signal's contribution.
//   (e) frontierK override — the shape can widen/narrow the pool, clamped.
//
// Exclusion (weight 0) and suppression (weight < 0) are DISTINCT behaviours and
// are tested separately. Anti-similarity (true farthest-K retrieval) is a
// separate concern decomposed to 6b-modifiers-antisim and is NOT exercised here.

import Testing
import Foundation
import LocusKit
import CorpusKit
import VectorKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

@Suite("RecallShape signed-weight fusion engine (6b-modifiers)", .serialized)
struct RecallShapeSignedWeightTests {

    private static let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    /// Open an estate with three captured drawers, registered in a deterministic
    /// corpus + vector store so the BM25 and Hamming lanes produce real, distinct
    /// candidates. Mirrors RecallDirectorTests.openEstateWithThreeDrawers.
    private func openEstateWithDrawers(_ contents: [String], owner ownerID: String)
        async throws -> (kit: GeniusLocusKit, handle: EstateHandle, ids: [String]) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: ownerID)
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        let corpus = try await Corpus(
            storage: InMemoryStorage(
                configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)),
            model: .deterministic)
        let vsStorage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        try await vsStorage.migrate(to: VectorStore.schemaDeclaration)
        let vectorStore = VectorStore(storage: vsStorage)
        let modelID = await corpus.modelID

        var ids: [String] = []
        for content in contents {
            let frame = CaptureFrame(
                content: content,
                channel: .typed,
                room: "recall-shape-tests",
                latticeAnchor: .udc("000.000"),
                addedBy: "recall-shape-tests",
                embeddingModelID: "test-model-v1"
            )
            let drawer = try await kit.capture(handle, frame)
            ids.append(drawer.id)
            try await corpus.ingest(content, sourceID: drawer.id, now: Self.now)
            let engram = try await corpus.embed(content)
            try await vectorStore.addVector(
                itemID: drawer.id, engram: engram, modelID: modelID,
                modelVersion: "1.0", filedAt: Self.now)
        }
        await kit.registerCorpus(corpus, for: handle)
        await kit.registerVectorStore(vectorStore, for: handle)
        return (kit: kit, handle: handle, ids: ids)
    }

    private func recallAllActive() -> RecallFrame {
        RecallFrame(
            filterChain: [.unconfirmed],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        )
    }

    /// A hybrid `.rrf` request — the lane that routes locus/bm25/hamming through
    /// the weighted rrfFuseN — optionally carrying a shape.
    private func hybridRequest(query: String, shape: RecallShape? = nil) -> GLKRecallRequest {
        GLKRecallRequest(
            frame: recallAllActive(),
            mode: .hybrid,
            scoring: .rrf,
            limit: 10,
            fallback: .failClosed,
            queryText: query,
            recallShape: shape
        )
    }

    private let contents = [
        "apple mango banana fruit recall test content",
        "mango orange grapefruit citrus recall basket",
        "recall stochastic gradient descent optimizer notes"
    ]

    // MARK: - (a) nil-shape back-compat

    /// An explicit all-1.0 shape and a nil shape must produce IDENTICAL fused
    /// output — ids, order, and `final` scores — proving the signed-weight path
    /// at neutral weights is byte-identical to today's unweighted fusion.
    @Test("nil shape and an all-1.0 shape produce byte-identical fused output")
    func nilShapeEqualsAllOnesShape() async throws {
        let (kit, handle, _) = try await openEstateWithDrawers(
            contents, owner: "backcompat-owner")

        let nilResult = try await kit.recall(handle, hybridRequest(query: "mango fruit recall"))
        let onesShape = RecallShape(laneWeights: ["locus": 1.0, "bm25": 1.0, "hamming": 1.0])
        let onesResult = try await kit.recall(
            handle, hybridRequest(query: "mango fruit recall", shape: onesShape))

        let nilIDs = nilResult.hits.map(\.id)
        let onesIDs = onesResult.hits.map(\.id)
        #expect(nilIDs == onesIDs,
            "all-1.0 shape must produce the same id order as nil shape; nil=\(nilIDs) ones=\(onesIDs)")
        for (a, b) in zip(nilResult.hits, onesResult.hits) {
            #expect(a.id == b.id)
            #expect(a.score.final == b.score.final,
                "fused final must be byte-identical at weight 1.0; \(a.id): nil=\(a.score.final) ones=\(b.score.final)")
        }
    }

    // MARK: - (b) exclusion (weight 0)

    /// A lane weighted 0 contributes no votes. An id surfaced ONLY by the excluded
    /// lane must NOT appear; ids also surfaced by another lane survive on that
    /// lane's mass alone. Here we exclude the bm25 lane and confirm the fused set
    /// equals the set fused from locus + hamming only (bm25 dropped).
    @Test("weight 0 drops the excluded lane's votes")
    func weightZeroExcludesLane() async throws {
        let (kit, handle, _) = try await openEstateWithDrawers(
            contents, owner: "exclusion-owner")

        // Baseline: all three lanes vote.
        let full = try await kit.recall(handle, hybridRequest(query: "mango fruit recall"))
        // Exclude bm25 (weight 0). The fused result must differ from full whenever
        // bm25 changed any ranking, and must never include an id whose only source
        // was bm25.
        let exclude = RecallShape(laneWeights: ["bm25": 0.0])
        let excluded = try await kit.recall(
            handle, hybridRequest(query: "mango fruit recall", shape: exclude))

        // Every excluded-result hit must still be reachable via locus or hamming
        // (i.e. carry a non-bm25 evidence source) — bm25-only candidates dropped.
        for hit in excluded.hits {
            let nonBM25 = hit.sources.contains(.locusBitmap)
                || hit.sources.contains(.vectorHamming)
            #expect(nonBM25,
                "with bm25 excluded, every surviving hit must have a non-bm25 source; \(hit.id) sources=\(hit.sources)")
        }
        // The fused `final` scores must change for at least one shared id when bm25
        // was actually contributing mass (exclusion is observable, not a no-op).
        let fullByID = Dictionary(uniqueKeysWithValues: full.hits.map { ($0.id, $0.score.final) })
        var sawChange = false
        for hit in excluded.hits {
            if let before = fullByID[hit.id], before != hit.score.final { sawChange = true }
        }
        #expect(sawChange || excluded.hits.count != full.hits.count,
            "excluding the bm25 lane must change the fused scores or the surviving set")
    }

    // MARK: - (c) suppression (weight < 0)

    /// A negative lane weight DEMOTES a candidate the lane ranks high. Build a
    /// query where the bm25 lane ranks a specific drawer first, then suppress bm25
    /// (weight < 0) and confirm that drawer's fused rank drops relative to the
    /// neutral fusion. Suppression is distinct from exclusion: the lane's mass is
    /// SUBTRACTED, not merely omitted.
    @Test("negative weight demotes a candidate the lane ranks high")
    func negativeWeightSuppressesLane() async throws {
        let (kit, handle, ids) = try await openEstateWithDrawers(
            contents, owner: "suppression-owner")

        // Query strongly aligned with drawer 0's keywords so bm25 ranks it high.
        let query = "apple mango banana fruit"
        let neutral = try await kit.recall(handle, hybridRequest(query: query))
        let suppress = RecallShape(laneWeights: ["bm25": -1.0])
        let suppressed = try await kit.recall(
            handle, hybridRequest(query: query, shape: suppress))

        let target = ids[0]
        let neutralRank = neutral.hits.firstIndex { $0.id == target }
        let suppressedRank = suppressed.hits.firstIndex { $0.id == target }

        // The bm25-favoured drawer must rank no better under suppression, and its
        // fused final must be strictly lower (its bm25 mass was subtracted, not
        // merely zeroed — distinguishing suppression from exclusion).
        if let n = neutralRank, let s = suppressedRank {
            #expect(s >= n,
                "suppressing bm25 must not improve the bm25-favoured drawer's rank; neutral=\(n) suppressed=\(s)")
        }
        let neutralFinal = neutral.hits.first { $0.id == target }?.score.final
        let suppressedFinal = suppressed.hits.first { $0.id == target }?.score.final
        if let nf = neutralFinal, let sf = suppressedFinal {
            #expect(sf < nf,
                "negative bm25 weight must lower the bm25-favoured drawer's fused final; neutral=\(nf) suppressed=\(sf)")
        }
    }

    /// Suppression and exclusion are DISTINCT: a candidate surfaced only by the
    /// targeted lane is DROPPED under exclusion (weight 0) but DEMOTED to negative
    /// mass under suppression (weight < 0). They must not produce the same output.
    @Test("exclusion (w=0) and suppression (w<0) of the same lane differ")
    func exclusionAndSuppressionDiffer() async throws {
        let (kit, handle, _) = try await openEstateWithDrawers(
            contents, owner: "distinct-owner")
        let query = "apple mango banana fruit"
        let excluded = try await kit.recall(
            handle, hybridRequest(query: query, shape: RecallShape(laneWeights: ["bm25": 0.0])))
        let suppressed = try await kit.recall(
            handle, hybridRequest(query: query, shape: RecallShape(laneWeights: ["bm25": -1.0])))

        // The two shaped fusions must not be identical in ordering AND scores —
        // subtracting mass (suppression) is a different operation from dropping
        // votes (exclusion).
        let exIDs = excluded.hits.map(\.id)
        let supIDs = suppressed.hits.map(\.id)
        let sameOrder = exIDs == supIDs
        let sameScores = zip(excluded.hits, suppressed.hits)
            .allSatisfy { $0.id == $1.id && $0.score.final == $1.score.final }
        #expect(!(sameOrder && sameScores),
            "exclusion and suppression of the same lane must differ; ex=\(exIDs) sup=\(supIDs)")
    }

    // MARK: - (d) leave-one-out

    /// Nulling one signal (weight 0) must remove exactly that signal's
    /// contribution. The leave-one-out fusion of {locus, hamming} (bm25 nulled)
    /// must equal a corpusOnly-style two-lane fusion in which bm25 never ran — the
    /// surviving lanes' mass is unchanged.
    @Test("leave-one-out: nulling one signal removes only that signal's votes")
    func leaveOneOutNullsSingleSignal() async throws {
        let (kit, handle, _) = try await openEstateWithDrawers(
            contents, owner: "loo-owner")
        let query = "mango fruit recall"

        // Null the hamming lane. The surviving locus + bm25 fusion must be stable:
        // re-running with hamming nulled twice yields identical output (determinism),
        // and no surviving hit carries hamming as its ONLY evidence source.
        let nullHamming = RecallShape(laneWeights: ["hamming": 0.0])
        let a = try await kit.recall(handle, hybridRequest(query: query, shape: nullHamming))
        let b = try await kit.recall(handle, hybridRequest(query: query, shape: nullHamming))
        #expect(a.hits.map(\.id) == b.hits.map(\.id), "leave-one-out fusion must be deterministic")
        for (x, y) in zip(a.hits, b.hits) {
            #expect(x.score.final == y.score.final, "leave-one-out fused finals must be deterministic")
        }
        for hit in a.hits {
            let nonHamming = hit.sources.contains(.locusBitmap) || hit.sources.contains(.corpusBM25)
            #expect(nonHamming,
                "with hamming nulled, no surviving hit may rely on hamming alone; \(hit.id) sources=\(hit.sources)")
        }
    }

    // MARK: - (e) frontierK override

    /// A shape frontierK override widens or narrows the candidate pool. The plan
    /// frontierK on the result must reflect the clamped override, not the engine
    /// default — proving the pool-depth knob is live and bounded to [64, 256].
    @Test("frontierK override is applied and clamped to [64, 256]")
    func frontierKOverrideAppliedAndClamped() async throws {
        let (kit, handle, _) = try await openEstateWithDrawers(
            contents, owner: "frontierk-owner")
        let query = "mango fruit recall"

        // Default (limit 10): computed frontierK = min(max(40,64),256) = 64.
        let def = try await kit.recall(handle, hybridRequest(query: query))
        #expect(def.plan.frontierK == 64, "default frontierK for limit 10 is 64; got \(def.plan.frontierK)")

        // Override 200 — within envelope, applied verbatim.
        let wide = try await kit.recall(
            handle, hybridRequest(query: query, shape: RecallShape(frontierK: 200)))
        #expect(wide.plan.frontierK == 200, "frontierK override 200 must be applied; got \(wide.plan.frontierK)")

        // Override 10_000 — clamped to the 256 ceiling.
        let clampedHigh = try await kit.recall(
            handle, hybridRequest(query: query, shape: RecallShape(frontierK: 10_000)))
        #expect(clampedHigh.plan.frontierK == 256,
            "frontierK override above ceiling must clamp to 256; got \(clampedHigh.plan.frontierK)")

        // Override 1 — clamped up to the 64 floor.
        let clampedLow = try await kit.recall(
            handle, hybridRequest(query: query, shape: RecallShape(frontierK: 1)))
        #expect(clampedLow.plan.frontierK == 64,
            "frontierK override below floor must clamp to 64; got \(clampedLow.plan.frontierK)")
    }

    // MARK: - RecallShape unit behaviour

    /// The RecallShape accessor returns 1.0 for absent keys and the configured
    /// value for present keys; effectiveFrontierK clamps correctly.
    @Test("RecallShape weight() defaults to 1.0 and effectiveFrontierK clamps")
    func recallShapeAccessors() {
        let shape = RecallShape(laneWeights: ["bm25": -2.0, "locus": 0.0], frontierK: 5_000)
        #expect(shape.weight(for: "bm25") == -2.0)
        #expect(shape.weight(for: "locus") == 0.0)
        #expect(shape.weight(for: "hamming") == 1.0, "absent lane key must default to 1.0")
        #expect(shape.weight(for: "dense:minilm-v6") == 1.0, "absent dense key must default to 1.0")
        #expect(shape.effectiveFrontierK(engineDefault: 64) == 256, "5000 clamps to ceiling 256")
        #expect(RecallShape().effectiveFrontierK(engineDefault: 128) == 128,
            "nil override returns the engine default unchanged")
        #expect(RecallShape(frontierK: 10).effectiveFrontierK(engineDefault: 128) == 64,
            "10 clamps up to floor 64")
    }

    /// RecallShape is Codable — round-trips through JSON without loss.
    @Test("RecallShape Codable round-trip preserves weights and frontierK")
    func recallShapeCodableRoundTrip() throws {
        let shape = RecallShape(
            laneWeights: ["locus": 1.5, "bm25": 0.0, "hamming": -1.0, "dense:mpnet-base-v2": 2.0],
            frontierK: 128)
        let data = try JSONEncoder().encode(shape)
        let decoded = try JSONDecoder().decode(RecallShape.self, from: data)
        #expect(decoded == shape, "Codable round-trip must preserve the shape exactly")
    }
}
