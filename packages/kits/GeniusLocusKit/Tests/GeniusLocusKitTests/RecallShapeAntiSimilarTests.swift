// RecallShapeAntiSimilarTests.swift
//
// Tests for 6b-modifiers-antisim: RecallShape.antiSimilarLanes wired into the
// unionBest dense lane. Anti-similarity (FARTHEST objective) is the "find things
// UNLIKE this" capability — it changes WHICH candidates the dense store returns
// (the most dissimilar), then forwards them into the same RRF/consensus fold.
//
// Observable design — dense PROVENANCE under frontierK truncation:
//   The dense lane retrieves only its top `frontierK` sources (≥ 64). With a
//   corpus LARGER than frontierK, the nearest pass keeps the most-similar
//   sources and DROPS the most-dissimilar tail; the farthest pass keeps the
//   most-dissimilar sources and drops the most-similar head. A drawer in the
//   dropped tail therefore carries `vectorDense:<modelID>` provenance ONLY when
//   its lane is anti-similar (farthest) — a clean, fixture-robust signal that a
//   reweighting (which never changes WHICH sources are retrieved) cannot produce.
//
//   • test (a)  — an anti-similar lane surfaces the most-dissimilar drawer
//                 (dense provenance present under anti-similar, absent under
//                 nearest).
//   • test (b)  — DISTINCTNESS: anti-similar+positive (the dissimilar drawer
//                 GAINS dense provenance) vs nearest+negative weight (it does
//                 NOT — never retrieved). The two are different mechanisms.
//   • test (c)  — anti-similar composes with a signed weight: same farthest
//                 retrieval, w>0 vs w<0 both target the dissimilar drawer.
//   • test (d)  — back-compat: nil vs empty antiSimilarLanes is byte-identical.
//
// The inference closure gives each drawer a distinct one-hot direction so the
// nearest/farthest ordering is deterministic and reproduces across Swift/Rust.

import Testing
import Foundation
import LocusKit
import CorpusKit
import VectorKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

@Suite("RecallShape.antiSimilarLanes — farthest objective in unionBest (6b-modifiers-antisim)", .serialized)
struct RecallShapeAntiSimilarTests {

    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private static let miniLMID = "minilm-v6"

    /// Number of drawers — must exceed the dense frontierK (pinned to the 64
    /// floor below) so the nearest and farthest passes keep DIFFERENT top-K
    /// source sets and the dense lane drops a most-dissimilar tail.
    private static let drawerCount = 80

    /// The dense candidate-pool depth, PINNED to the engine floor (64) via the
    /// RecallShape `frontierK` override so it is independent of the request
    /// `limit`. With `drawerCount` (80) > 64 the dense lane must drop 16 sources;
    /// nearest drops the most-dissimilar tail, farthest drops the most-similar
    /// head. The request `limit` stays large so the dropped drawers still appear
    /// in the RESULT (via the locus lane) — only their DENSE provenance differs.
    private static let pinnedFrontierK = 64

    /// A `.rrf`-scored unionBest recall frame. Every request pins `frontierK` to
    /// the floor (64) so the dense top-K truncation is observable. `extra`
    /// supplies any per-test lane weights / anti-similar lanes; `frontierK` is
    /// always merged in. A nil `extra` still yields a shape (frontierK only),
    /// which the back-compat test treats as the neutral baseline.
    private func unionBestRRF(
        query: String,
        laneWeights: [String: Float] = [:],
        antiSimilarLanes: Set<String> = [],
        limit: Int = drawerCount
    ) -> GLKRecallRequest {
        let shape = RecallShape(
            laneWeights: laneWeights,
            antiSimilarLanes: antiSimilarLanes,
            frontierK: Self.pinnedFrontierK
        )
        return GLKRecallRequest(
            frame: RecallFrame(
                filterChain: [.unconfirmed],
                hydrationLevel: .structured,
                ordering: .byCaptureTimeDesc
            ),
            mode: .unionBest,
            scoring: .rrf,
            limit: limit,
            queryText: query,
            origin: .internal,
            recallShape: shape
        )
    }

    /// Open a SINGLE-provider estate with `drawerCount` drawers. Drawer i is
    /// captured with content whose FNV-1a lead token routes a one-hot direction;
    /// `query` aligns (same direction) with drawer 0. The directions are spread
    /// across distinct axes so cosine ordering is deterministic and the dense
    /// top-K truncation drops a well-defined tail.
    ///
    /// Returns the kit, handle, the captured drawer ids (index-aligned), and the
    /// query string aligned to drawer 0.
    private func openLargeEstate(owner ownerID: String)
        async throws -> (kit: GeniusLocusKit, handle: EstateHandle, ids: [String], query: String) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: ownerID)
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        let corpusStorage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        // MONOTONIC cosine spread: a drawer's direction is [cos θ, sin θ, 0…] with
        // θ proportional to its token COUNT. The query has the fewest tokens (θ≈0),
        // so cosine-to-query decreases monotonically as a drawer's token count
        // grows — drawer i (i filler words) is the i-th most dissimilar. This makes
        // "most dissimilar" UNAMBIGUOUS (no cosine ties), so the dense top-K
        // truncation drops a well-defined tail and the farthest pass keeps a
        // well-defined head. The query's own count is pinned smallest below.
        let corpus = try await CorpusContentEngine(
            standaloneOn: corpusStorage,
            models: [.miniLM(inference: { tokens in
                // θ scaled so 0…drawerCount tokens sweeps ~0…90°: orthogonal at the
                // far end, identical at the near end. 0.018 rad/token ≈ 82° at i=80.
                let theta = Float(tokens.count) * 0.018
                var v = Array(repeating: Float(0), count: 384)
                v[0] = Foundation.cos(theta)
                v[1] = Foundation.sin(theta)
                return v
            })]
        )
        let vsStorage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        try await vsStorage.migrate(to: VectorStore.schemaDeclaration)
        let vectorStore = VectorStore(storage: vsStorage)
        let hammingModelID = await corpus.modelID

        // Drawer i has a distinct token COUNT (i + 2 words) so its direction angle
        // θ(i) is monotonic in i; drawer 0 (fewest words) is closest to the query.
        // Each drawer also carries a unique lead word so BM25/Hamming still treat
        // them as distinct documents.
        var ids: [String] = []
        for i in 0..<Self.drawerCount {
            let filler = Array(repeating: "word", count: i + 1).joined(separator: " ")
            let content = "doc\(i) \(filler)"
            let frame = CaptureFrame(
                content: content,
                channel: .typed,
                room: "recall-shape-antisim-tests",
                latticeAnchor: .udc("000"),
                addedBy: "recall-shape-antisim-tests",
                embeddingModelID: "test-model-v1"
            )
            let drawer = try await kit.capture(handle, frame)
            ids.append(drawer.id)
            try await corpus.ingest(content, contentID: drawer.id, now: Self.t0)
            let engram = try await corpus.embed(content)
            try await vectorStore.addVector(
                itemID: drawer.id, engram: engram, modelID: hammingModelID,
                modelVersion: "1.0", filedAt: Self.t0)
        }
        await kit.registerCorpus(corpus, for: handle)
        await kit.registerVectorStore(vectorStore, for: handle)
        // Query: a single token → θ≈0 → closest to the low-index drawers, farthest
        // from the high-index drawers (the most-dissimilar tail the dense top-K
        // truncates under nearest).
        let query = "queryword"
        return (kit: kit, handle: handle, ids: ids, query: query)
    }

    /// Whether the dense lane voted for `id` (the `vectorDense:<miniLMID>`
    /// provenance token is present on that hit's explanation).
    private func hasDenseProvenance(_ id: String, in result: GLKRecallResult) -> Bool {
        (result.hits.first { $0.id == id }?.explanation ?? [])
            .joined(separator: " | ")
            .contains("vectorDense:\(Self.miniLMID)")
    }

    /// Find a drawer that the dense lane drops under NEAREST (no dense provenance)
    /// but is present in the corpus — i.e. a most-dissimilar tail drawer. Returns
    /// its id, or nil if the truncation did not drop any provenance (corpus too
    /// small — a test setup error).
    private func someNearestDroppedDrawer(_ result: GLKRecallResult, ids: [String]) -> String? {
        // Scan from the most-dissimilar end (high indices) for a drawer present in
        // the result but WITHOUT dense provenance under nearest.
        for id in ids.reversed() where result.hits.contains(where: { $0.id == id }) {
            if !hasDenseProvenance(id, in: result) { return id }
        }
        return nil
    }

    // MARK: - (a) anti-similar lane surfaces dissimilar drawers

    /// A drawer in the most-dissimilar tail is DROPPED from the dense top-K under
    /// nearest (no dense provenance), but RETRIEVED under anti-similarity (the
    /// lane now keeps the farthest sources) — so it gains `vectorDense` provenance.
    /// A reweighting cannot move provenance to a drawer the lane never retrieved,
    /// so this is the anti-similarity signature.
    @Test("an anti-similar dense lane surfaces dissimilar drawers in unionBest")
    func antiSimilarLaneSurfacesDissimilar() async throws {
        let (kit, handle, ids, query) = try await openLargeEstate(owner: "antisim-surface-owner")

        let nearest = try await kit.recall(handle, unionBestRRF(query: query))
        let dropped = someNearestDroppedDrawer(nearest, ids: ids)
        let droppedID = try #require(dropped,
            "test setup: the corpus must exceed frontierK so the dense top-K drops a dissimilar tail")
        // Sanity: the dropped drawer has no dense provenance under nearest.
        #expect(!hasDenseProvenance(droppedID, in: nearest))

        let anti = try await kit.recall(
            handle, unionBestRRF(query: query, antiSimilarLanes: ["dense:\(Self.miniLMID)"]))
        // Under anti-similarity the most-dissimilar drawers are now the dense
        // lane's top-K, so the tail drawer nearest dropped now gains dense provenance.
        #expect(hasDenseProvenance(droppedID, in: anti),
            "anti-similar dense lane must surface the dissimilar drawer that nearest dropped")
    }

    // MARK: - (b) DISTINCTNESS — anti-sim+positive ≠ nearest+negative

    /// The mission's core invariant: anti-similarity (forward the dissimilar) and
    /// a negative weight (demote the similar) are DISTINCT operations and produce
    /// DIFFERENT results on the same fixture.
    ///
    ///   • anti-similar + positive weight — the store returns the FARTHEST sources
    ///     and FORWARDS them: a most-dissimilar tail drawer GAINS dense provenance.
    ///   • nearest + negative weight       — the store returns the NEAREST sources
    ///     and SUBTRACTS their mass: a most-dissimilar tail drawer gains NO dense
    ///     provenance (it was never retrieved — only its rank mass, had it been
    ///     near, would be subtracted).
    ///
    /// The decisive, fixture-robust distinction is dense provenance on the
    /// dissimilar drawer: present under anti-similarity, absent under a negative
    /// weight.
    @Test("anti-similar+positive weight differs from nearest+negative weight")
    func antiSimilarDistinctFromNegativeWeight() async throws {
        let (kit, handle, ids, query) = try await openLargeEstate(owner: "antisim-distinct-owner")
        let denseKey = "dense:\(Self.miniLMID)"

        let baseline = try await kit.recall(handle, unionBestRRF(query: query))
        let droppedID = try #require(someNearestDroppedDrawer(baseline, ids: ids),
            "test setup: the corpus must exceed frontierK so a dissimilar tail drawer is dropped")

        // anti-similar + positive (forward the dissimilar).
        let antiResult = try await kit.recall(
            handle, unionBestRRF(query: query, laneWeights: [denseKey: 1.0],
                                 antiSimilarLanes: [denseKey]))

        // nearest + negative (demote the similar). NOT anti-similar.
        let negResult = try await kit.recall(
            handle, unionBestRRF(query: query, laneWeights: [denseKey: -1.0]))

        // Anti-similarity gives the dissimilar drawer dense provenance…
        #expect(hasDenseProvenance(droppedID, in: antiResult),
            "anti-similar path must give the dissimilar drawer dense provenance (it forwards the farthest)")
        // …whereas the negative-weight path never retrieves it — no dense provenance.
        #expect(!hasDenseProvenance(droppedID, in: negResult),
            "negative-weight path must NOT give the dissimilar drawer dense provenance (never retrieved)")
    }

    // MARK: - (c) anti-similar composes with a signed weight

    /// A lane can be anti-similar AND signed — the store returns the FARTHEST
    /// sources, then the lane FORWARDS (w>0) or SUPPRESSES (w<0) them. Both target
    /// the dissimilar (farthest) drawer — the anti-similar RETRIEVAL is the same;
    /// only the vote sign differs. Both therefore give the dissimilar drawer dense
    /// provenance (a w<0 signal still contributed — subtracted — mass).
    @Test("anti-similar composes with a signed weight")
    func antiSimilarComposesWithWeight() async throws {
        let (kit, handle, ids, query) = try await openLargeEstate(owner: "antisim-compose-owner")
        let denseKey = "dense:\(Self.miniLMID)"

        let baseline = try await kit.recall(handle, unionBestRRF(query: query))
        let droppedID = try #require(someNearestDroppedDrawer(baseline, ids: ids),
            "test setup: the corpus must exceed frontierK so a dissimilar tail drawer is dropped")

        let forwardResult = try await kit.recall(
            handle, unionBestRRF(query: query, laneWeights: [denseKey: 1.0],
                                 antiSimilarLanes: [denseKey]))
        let suppressResult = try await kit.recall(
            handle, unionBestRRF(query: query, laneWeights: [denseKey: -1.0],
                                 antiSimilarLanes: [denseKey]))

        // Both anti-similar paths retrieved the dissimilar drawer (same farthest
        // scan) — proving the anti-similar RETRIEVAL is independent of vote sign.
        #expect(hasDenseProvenance(droppedID, in: forwardResult),
            "anti-similar+forward must give the dissimilar drawer dense provenance")
        #expect(hasDenseProvenance(droppedID, in: suppressResult),
            "anti-similar+suppress still contributed (negative) mass to the dissimilar drawer")
    }

    // MARK: - (d) back-compat — nil/empty antiSimilarLanes is byte-identical

    /// nil shape and an explicit empty-anti-similar shape must produce
    /// BYTE-IDENTICAL unionBest output — ids, order, fused finals, and dense
    /// column. This is the back-compat contract: no anti-similar lane ⇒ every
    /// dense lane is nearest ⇒ today's behaviour.
    @Test("nil shape and empty antiSimilarLanes are byte-identical in unionBest")
    func emptyAntiSimilarEqualsNil() async throws {
        let (kit, handle, _, query) = try await openLargeEstate(owner: "antisim-backcompat-owner")

        // A genuinely nil shape (the pre-antisim production path) and an explicit
        // empty-anti-similar shape with otherwise-neutral weights must produce
        // BYTE-IDENTICAL output. Both use the engine's default frontierK (no
        // override) so the whole corpus is in the dense pool — a pure back-compat
        // comparison with no truncation involved.
        func req(_ shape: RecallShape?) -> GLKRecallRequest {
            GLKRecallRequest(
                frame: RecallFrame(
                    filterChain: [.unconfirmed],
                    hydrationLevel: .structured,
                    ordering: .byCaptureTimeDesc),
                mode: .unionBest, scoring: .rrf, limit: Self.drawerCount,
                queryText: query, origin: .internal, recallShape: shape)
        }
        let emptyShape = RecallShape(antiSimilarLanes: [])

        let nilResult = try await kit.recall(handle, req(nil))
        let emptyResult = try await kit.recall(handle, req(emptyShape))

        #expect(nilResult.hits.map(\.id) == emptyResult.hits.map(\.id),
            "empty antiSimilarLanes must produce the same unionBest id order as nil shape")
        for (a, b) in zip(nilResult.hits, emptyResult.hits) {
            #expect(a.id == b.id)
            #expect(a.score.final == b.score.final,
                "unionBest fused final must be byte-identical; \(a.id): nil=\(a.score.final) empty=\(b.score.final)")
            #expect(a.score.dense == b.score.dense,
                "unionBest dense column must be byte-identical; \(a.id): nil=\(a.score.dense) empty=\(b.score.dense)")
        }
    }
}
