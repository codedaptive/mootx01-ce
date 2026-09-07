// RecallHybridShapeTests.swift
//
// Pins for the lane columns a hybrid or corpusOnly hit carries, and for the
// lane roster of the hybrid path. Parity peer of Rust
// recall_hybrid_shape_parity.rs; the two files pin the same values.
//
// Contract (GENIUSLOCUSKIT_SPEC 3.5.0): under every scoring, a hit returned by
// Hybrid or CorpusOnly recall carries PER-SIGNAL lane columns. `locus` is the
// locus ramp `(frontierK - rank) / frontierK` when the locus lane supplied the
// hit, `bm25` is the BM25 score when the BM25 lane supplied it, `vector` is the
// Hamming similarity `(256 - distance) / 256` when the vector lane supplied it,
// and each column is 0 where its lane did not supply the hit. `final` is the
// fused or merged score and the ranking reads `final` alone. The hybrid path
// fuses the locus, BM25 and vector lanes and no other: a drawer only a tunnel
// would reach is not a hybrid candidate.
//
// Tests:
//  1. hybridRrfHitsCarryPerSignalColumns: four drawers, two with the query
//     word, two in the vector store. Under hybrid `.rrf` the hit every lane
//     supplied, the hits two lanes supplied and the locus-only hit each carry
//     their lanes' own scores and 0 elsewhere.
//  2. hybridRawHitsCarryPerSignalColumns: the same estate under `.raw`.
//  3. corpusOnlyRrfHitsCarryPerSignalColumns: the same estate under corpusOnly
//     `.rrf`: `locus` is 0 on every hit, the BM25-only and vector-only hits
//     carry one column, the locus-only drawer is absent.
//  4. hybridRrfDoesNotSupplyGraphOnlyCandidates: a drawer outside the locus
//     frontier reached only by a tunnel from the newest drawer is absent from
//     hybrid `.rrf` hits and lane ranks; the unionBest graph lane reaches it
//     (control), so the fixture is real.

import Testing
import Foundation
import LocusKit
import CorpusKit
import SynapseKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

@Suite("Recall hybrid and corpusOnly hit columns are per-signal; hybrid has no graph lane")
struct RecallHybridShapeTests {

    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    /// `min(max(limit * 4, 64), 256)` for every limit at or below 16.
    private static let frontierK = 64

    // MARK: - Estate factory

    private func openEstate(owner ownerID: String) async throws -> (kit: GeniusLocusKit, handle: EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: ownerID)
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    private func captureDrawer(content: String, kit: GeniusLocusKit, handle: EstateHandle) async throws -> Drawer {
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: "shape-room",
            latticeAnchor: .udc("000"),
            addedBy: "shape-tests",
            embeddingModelID: "test-model-v1"
        )
        return try await kit.capture(handle, frame)
    }

    /// Recall frame matching every currently-believed row.
    private func activeFrame() -> RecallFrame {
        RecallFrame(
            filterChain: [.unconfirmed],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        )
    }

    private func request(mode: GLKRecallMode, scoring: GLKRecallScoring, limit: Int, query: String?) -> GLKRecallRequest {
        GLKRecallRequest(
            frame: activeFrame(),
            mode: mode,
            scoring: scoring,
            limit: limit,
            fallback: .allowDegraded,
            queryText: query,
            origin: .internal
        )
    }

    /// The locus ramp for a zero-based rank at the default frontier.
    private func ramp(_ rank: Int) -> Float {
        Float(Self.frontierK - rank) / Float(Self.frontierK)
    }

    /// A bag-of-tokens direction: every token adds a cosine ridge keyed on
    /// its id, so two texts that share a token share part of their direction
    /// and the Hamming lane ranks the text sharing the query word nearer than
    /// one that shares none. The same closure as the Rust twin's `MiniLM`
    /// inference. (A direction that varies in two dimensions alone never
    /// flips a +-1 SimHash plane, so token count alone cannot separate
    /// drawers.)
    private func makeCorpus() async throws -> CorpusContentEngine {
        let corpusStorage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        return try await CorpusContentEngine(
            standaloneOn: corpusStorage,
            models: [.miniLM(inference: { tokens in
                var v = Array(repeating: Float(0), count: 384)
                for tok in tokens {
                    let key = Float(((tok % 251) + 251) % 251 + 1)
                    for j in 0..<v.count {
                        v[j] += Foundation.cos(key * (Float(j) + 1.0) * 0.1)
                    }
                }
                return v
            })]
        )
    }

    private func makeVectorStore() async throws -> VectorStore {
        let vsStorage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        try await vsStorage.migrate(to: VectorStore.schemaDeclaration)
        return VectorStore(storage: vsStorage)
    }

    /// The lane oracles for the four-drawer estate, read from the corpus and
    /// the vector store directly so the pins do not depend on the director.
    private struct LaneOracle {
        /// BM25 score by drawer id for the query, from `bm25TopKBySource`.
        let bm25: [String: Float]
        /// Hamming similarity `(256 - distance) / 256` by drawer id for the
        /// query engram, from `findNearest`.
        let vector: [String: Float]
    }

    /// Four drawers, oldest first:
    ///   ids[0] "doc0 queryword alpha": query word, in the vector store (three lanes)
    ///   ids[1] "doc1 queryword beta beta beta beta": query word, not in the store
    ///          (locus + BM25); longer, so BM25 ranks it below ids[0]
    ///   ids[2] "doc2 gamma delta":     no query word, in the store (locus + vector);
    ///          it shares no token with the query, so it sits further from the
    ///          query than ids[0], which shares the query word
    ///   ids[3] "doc3 epsilon zeta":    no query word, not in the store (locus only)
    /// The locus lane ranks newest first, so ids[3] has locus rank 0. No lane
    /// holds a tie, so every rank the RRF pins read is fixed.
    private func openFourDrawerEstate() async throws -> (kit: GeniusLocusKit, handle: EstateHandle, ids: [String], query: String, oracle: LaneOracle) {
        let (kit, handle) = try await openEstate(owner: "owner-shape-four")
        let corpus = try await makeCorpus()
        let vectorStore = try await makeVectorStore()
        let hammingModelID = await corpus.modelID
        let query = "queryword"
        let contents = ["doc0 queryword alpha", "doc1 queryword beta beta beta beta", "doc2 gamma delta", "doc3 epsilon zeta"]
        let inStore: Set<Int> = [0, 2]
        var ids: [String] = []
        for (i, content) in contents.enumerated() {
            let drawer = try await captureDrawer(content: content, kit: kit, handle: handle)
            try await corpus.ingest(content, contentID: drawer.id, now: Self.t0)
            if inStore.contains(i) {
                let engram = try await corpus.embed(content)
                try await vectorStore.addVector(
                    itemID: drawer.id, engram: engram, modelID: hammingModelID,
                    modelVersion: "1.0", filedAt: Self.t0)
            }
            ids.append(drawer.id)
        }
        await kit.registerCorpus(corpus, for: handle)
        await kit.registerVectorStore(vectorStore, for: handle)

        var bm25: [String: Float] = [:]
        for hit in try await corpus.bm25TopKBySource(query: query, limit: Self.frontierK) {
            bm25[hit.sourceID] = hit.score
        }
        var vector: [String: Float] = [:]
        let probe = try await corpus.embed(query)
        for m in try await vectorStore.findNearest(probe: probe, modelID: hammingModelID, limit: Self.frontierK) {
            vector[m.itemID] = Float(256 - m.distance) / 256.0
        }
        #expect(Set(bm25.keys) == Set([ids[0], ids[1]]), "BM25 matches the two query-word drawers (got \(bm25.keys))")
        #expect(Set(vector.keys) == Set([ids[0], ids[2]]), "the vector store holds two drawers (got \(vector.keys))")
        #expect((bm25[ids[0]] ?? 0) > (bm25[ids[1]] ?? 0), "the shorter query-word drawer leads BM25 (no tie): \(bm25)")
        #expect((vector[ids[0]] ?? 0) > (vector[ids[2]] ?? 0), "the drawer sharing the query word is nearer the query (no tie): \(vector)")
        return (kit, handle, ids, query, LaneOracle(bm25: bm25, vector: vector))
    }

    /// The columns a hybrid hit for `id` must carry: the locus ramp at its
    /// locus rank, the BM25 oracle or 0, the Hamming oracle or 0.
    private func expectHybridColumns(_ hit: RecallHit, locusRank: Int, oracle: LaneOracle, label: String) {
        let wantLocus = ramp(locusRank)
        let wantBm25 = oracle.bm25[hit.id] ?? 0
        let wantVector = oracle.vector[hit.id] ?? 0
        #expect(abs(hit.score.locus - wantLocus) < 1e-6,
                "\(label): locus is the ramp \(wantLocus), got \(hit.score.locus)")
        #expect(abs(hit.score.bm25 - wantBm25) < 1e-6,
                "\(label): bm25 is the BM25 lane score \(wantBm25), got \(hit.score.bm25)")
        #expect(abs(hit.score.vector - wantVector) < 1e-6,
                "\(label): vector is the Hamming similarity \(wantVector), got \(hit.score.vector)")
        #expect(hit.sources.contains(.locusBitmap), "\(label): the locus lane supplied it")
        #expect(hit.sources.contains(.corpusBM25) == (wantBm25 > 0), "\(label): BM25 provenance matches the column")
        #expect(hit.sources.contains(.vectorHamming) == (wantVector > 0), "\(label): vector provenance matches the column")
        #expect(!hit.sources.contains(.locusGraph), "\(label): hybrid has no graph lane")
    }

    // MARK: - 1. Hybrid .rrf

    /// Twin of Rust `hybrid_rrf_hits_carry_per_signal_columns`.
    @Test("hybrid .rrf hits carry each lane's own score and 0 where a lane did not supply the hit")
    func hybridRrfHitsCarryPerSignalColumns() async throws {
        let (kit, handle, ids, query, oracle) = try await openFourDrawerEstate()

        let result = try await kit.recall(handle, request(mode: .hybrid, scoring: .rrf, limit: 10, query: query))

        #expect(result.hits.count == 4, "every drawer is a locus candidate (got \(result.hits.count))")
        let byID = Dictionary(uniqueKeysWithValues: result.hits.map { ($0.id, $0) })
        let three = try #require(byID[ids[0]], "the three-lane drawer surfaces")
        let locusBm25 = try #require(byID[ids[1]], "the locus + BM25 drawer surfaces")
        let locusVector = try #require(byID[ids[2]], "the locus + vector drawer surfaces")
        let locusOnly = try #require(byID[ids[3]], "the locus-only drawer surfaces")
        expectHybridColumns(three, locusRank: 3, oracle: oracle, label: "three lanes")
        expectHybridColumns(locusBm25, locusRank: 2, oracle: oracle, label: "locus + BM25")
        expectHybridColumns(locusVector, locusRank: 1, oracle: oracle, label: "locus + vector")
        expectHybridColumns(locusOnly, locusRank: 0, oracle: oracle, label: "locus only")

        // The three-lane drawer holds the reciprocal-rank sum of its three
        // ranks (first in BM25 and vector, fourth in locus) and leads.
        let wantFinal: Float = 1.0 / (60 + 4) + 1.0 / (60 + 1) + 1.0 / (60 + 1)
        #expect(abs(three.score.final - wantFinal) < 1e-6,
                "three lanes: final is the RRF sum \(wantFinal), got \(three.score.final)")
        #expect(result.hits.first?.id == ids[0], "the three-lane drawer leads under RRF")
        // A column never equals the fused final by construction: the ramp is at
        // least 0.95 here and an RRF sum at most 3/61.
        for hit in result.hits {
            #expect(hit.score.locus != hit.score.final, "\(hit.id): locus is not the fused final")
        }
    }

    // MARK: - 2. Hybrid .raw

    /// Twin of Rust `hybrid_raw_hits_carry_per_signal_columns`.
    @Test("hybrid .raw hits carry each lane's own score and the locus ramp as final")
    func hybridRawHitsCarryPerSignalColumns() async throws {
        let (kit, handle, ids, query, oracle) = try await openFourDrawerEstate()

        let result = try await kit.recall(handle, request(mode: .hybrid, scoring: .raw, limit: 10, query: query))

        #expect(result.hits.map(\.id) == Array(ids.reversed()), "raw is the locus order, newest first")
        for (rank, hit) in result.hits.enumerated() {
            expectHybridColumns(hit, locusRank: rank, oracle: oracle, label: "raw rank \(rank)")
            #expect(abs(hit.score.final - ramp(rank)) < 1e-6,
                    "raw rank \(rank): final is the locus ramp \(ramp(rank)), got \(hit.score.final)")
        }
    }

    // MARK: - 3. CorpusOnly .rrf

    /// Twin of Rust `corpus_only_rrf_hits_carry_per_signal_columns`.
    @Test("corpusOnly .rrf hits carry the BM25 score and the Hamming similarity, locus 0")
    func corpusOnlyRrfHitsCarryPerSignalColumns() async throws {
        let (kit, handle, ids, query, oracle) = try await openFourDrawerEstate()

        let result = try await kit.recall(handle, request(mode: .corpusOnly, scoring: .rrf, limit: 10, query: query))

        #expect(Set(result.hits.map(\.id)) == Set([ids[0], ids[1], ids[2]]),
                "the BM25 and vector lanes supply three drawers; the locus-only drawer is absent (got \(result.hits.map(\.id)))")
        let byID = Dictionary(uniqueKeysWithValues: result.hits.map { ($0.id, $0) })
        for id in [ids[0], ids[1], ids[2]] {
            let hit = try #require(byID[id], "\(id) surfaces")
            let wantBm25 = oracle.bm25[id] ?? 0
            let wantVector = oracle.vector[id] ?? 0
            #expect(hit.score.locus == 0, "\(id): corpusOnly has no locus lane (got \(hit.score.locus))")
            #expect(abs(hit.score.bm25 - wantBm25) < 1e-6,
                    "\(id): bm25 is the BM25 lane score \(wantBm25), got \(hit.score.bm25)")
            #expect(abs(hit.score.vector - wantVector) < 1e-6,
                    "\(id): vector is the Hamming similarity \(wantVector), got \(hit.score.vector)")
            #expect(hit.sources.contains(.corpusBM25) == (wantBm25 > 0), "\(id): BM25 provenance matches the column")
            #expect(hit.sources.contains(.vectorHamming) == (wantVector > 0), "\(id): vector provenance matches the column")
        }
        // The BM25-only and vector-only hits carry exactly one column, and it
        // is the lane score, never the reciprocal-rank final.
        let bm25Only = try #require(byID[ids[1]])
        #expect(bm25Only.score.vector == 0 && bm25Only.score.bm25 > 0, "BM25-only: one column")
        #expect(bm25Only.score.bm25 != bm25Only.score.final, "BM25-only: the column is not the fused final")
        let vectorOnly = try #require(byID[ids[2]])
        #expect(vectorOnly.score.bm25 == 0 && vectorOnly.score.vector > 0, "vector-only: one column")
        #expect(vectorOnly.score.vector != vectorOnly.score.final, "vector-only: the column is not the fused final")
        // The two-lane drawer holds the reciprocal-rank sum of its two first ranks.
        let two = try #require(byID[ids[0]])
        let wantFinal: Float = 1.0 / (60 + 1) + 1.0 / (60 + 1)
        #expect(abs(two.score.final - wantFinal) < 1e-6,
                "two lanes: final is the RRF sum \(wantFinal), got \(two.score.final)")
    }

    // MARK: - 4. Hybrid has no graph lane

    /// Twin of Rust `hybrid_rrf_does_not_supply_graph_only_candidates`.
    ///
    /// Sixty-five drawers, so at the default frontier of 64 the oldest drawer
    /// falls outside the locus window. A tunnel from the newest drawer reaches
    /// it. The corpus holds the newest drawer only, so the BM25 lane never
    /// supplies the target either: only a graph lane would. Hybrid `.rrf`
    /// returns no such hit and records no graph rank; unionBest, which has the
    /// graph lane, records the target at graph rank 1 (the fixture control).
    @Test("hybrid .rrf never returns a drawer only a tunnel would reach")
    func hybridRrfDoesNotSupplyGraphOnlyCandidates() async throws {
        let (kit, handle) = try await openEstate(owner: "owner-shape-graph")
        let estate = try await kit.estate(for: handle)
        let corpus = try await makeCorpus()
        let query = "queryword"

        // Content strings sort the same way as capture time under the stable
        // locus sort (filedAt DESC, then content DESC): "zz" leads and "0"
        // trails, so the window is the same whether or not captures share a
        // timestamp.
        let target = try await captureDrawer(content: "0 tunnel target", kit: kit, handle: handle)
        var newest = target
        for i in 1..<Self.frontierK {
            newest = try await captureDrawer(content: "doc\(i) filler", kit: kit, handle: handle)
        }
        let newestContent = "zz newest queryword"
        newest = try await captureDrawer(content: newestContent, kit: kit, handle: handle)
        try await corpus.ingest(newestContent, contentID: newest.id, now: Self.t0)
        await kit.registerCorpus(corpus, for: handle)

        let tunnelFrame = TunnelCaptureFrame(
            sourceWing: "shape-room", sourceRoom: "shape-room",
            targetWing: "shape-room", targetRoom: "shape-room",
            label: "shape-graph-link",
            addedBy: "shape-tests",
            sourceDrawerId: newest.id,
            targetDrawerId: target.id,
            kind: .references
        )
        _ = try await estate.capture(tunnelFrame)

        let hybrid = try await kit.recall(handle, request(mode: .hybrid, scoring: .rrf, limit: 10, query: query))
        #expect(!hybrid.hits.isEmpty, "the hybrid recall returns the locus and BM25 candidates")
        #expect(hybrid.hits.first?.id == newest.id, "the newest drawer leads: locus rank 1 and BM25 rank 1")
        #expect(!hybrid.hits.contains { $0.id == target.id },
                "hybrid has no graph lane, so the tunnel target outside the locus frontier is absent")
        #expect(hybrid.laneRanks[target.id] == nil,
                "no hybrid lane ranked the target (got \(String(describing: hybrid.laneRanks[target.id])))")
        #expect(!hybrid.hits.contains { $0.sources.contains(.locusGraph) }, "no hybrid hit carries locusGraph")
        #expect(hybrid.laneRanks[newest.id]?["locus"] == 1 && hybrid.laneRanks[newest.id]?["bm25"] == 1,
                "the newest drawer is rank 1 in both hybrid lanes (got \(String(describing: hybrid.laneRanks[newest.id])))")

        // Control: the unionBest graph lane reaches the target through the
        // tunnel, so the fixture really does put it one tunnel away.
        let union = try await kit.recall(handle, request(mode: .unionBest, scoring: .rrf, limit: 10, query: query))
        #expect(union.laneRanks[target.id]?["graph"] == 1,
                "unionBest records the target at graph rank 1 (got \(String(describing: union.laneRanks[target.id])))")
        #expect(union.laneRanks[target.id]?["locus"] == nil,
                "the target sits outside the 64-wide locus frontier")
    }
}
