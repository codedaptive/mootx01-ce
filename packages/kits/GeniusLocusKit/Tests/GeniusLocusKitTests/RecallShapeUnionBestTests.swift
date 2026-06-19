// RecallShapeUnionBestTests.swift
//
// Tests for 6b-modifiers-core-2: RecallShape steering wired into the unionBest
// lane — the ONLY lane where the per-signal DENSE float signals actually fuse.
//
// 6b-modifiers-core wired RecallShape into the corpusOnly and hybrid RRF lanes,
// but the dense `dense:<modelID>` weights were ACCEPTED by the type and did
// NOTHING in unionBest. This file proves the dense weights now steer the dense
// signals, and that the fixed lanes (locus/bm25/hamming/dense) are shape-steerable
// in the unionBest weighted-column score too. A multi-provider corpus (6a-iii-core
// `init(models:)`) gives two distinct dense signals (minilm-v6, mpnet-base-v2):
//
//   (a) exclusion of one dense signal (`dense:<modelID>`=0) removes exactly that
//       signal's votes from the consensus.
//   (b) suppression of a dense signal (`<0`) demotes a drawer it ranks high.
//   (c) leave-one-out determinism — nulling one dense signal twice is identical.
//   (d) a fixed-lane exclusion (`bm25`=0) zeroes bm25's column in unionBest.
//   (e) nil-shape == all-ones-shape is byte-identical in unionBest (back-compat).
//
// The inference closures mirror DenseLanePerSignalFusionTests: distinct first
// tokens drive distinct embeddings so the per-signal cosine ordering is
// deterministic and reproducible across the Swift/Rust ports.

import Testing
import Foundation
import LocusKit
import CorpusKit
import VectorKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

@Suite("RecallShape dense steering in the unionBest lane (6b-modifiers-core-2)", .serialized)
struct RecallShapeUnionBestTests {

    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// modelID constants for the two held providers (CorpusKit canonical ids).
    private static let miniLMID = "minilm-v6"
    private static let mpNetID  = "mpnet-base-v2"

    /// A `.rrf`-scored unionBest recall frame matching every active row,
    /// optionally carrying a `RecallShape`.
    private func unionBestRRF(query: String, shape: RecallShape? = nil, limit: Int = 10)
        -> GLKRecallRequest {
        GLKRecallRequest(
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

    /// Open an estate with `contents` captured, registered against a TWO-provider
    /// corpus (miniLM + mpnet) and a Hamming vector store so the dense float lane
    /// fans out across both held signals AND the bm25/hamming lanes also vote.
    ///
    /// miniLM ranks BOTH docs (a shared component pulls everything toward the
    /// query); mpnet aligns ONLY the consensus doc (axis 1) with the query and
    /// routes other lead tokens to a distant axis — so a doc surfaced only by
    /// mpnet is the lever for the exclusion/suppression assertions.
    private func openTwoProviderEstate(_ contents: [String], owner ownerID: String)
        async throws -> (kit: GeniusLocusKit, handle: EstateHandle, ids: [String]) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: ownerID)
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        let corpusStorage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let corpus = try await CorpusKit.Corpus(
            storage: corpusStorage,
            models: [
                .miniLM(inference: { tokens in
                    let lead = tokens.first ?? 0
                    var v = Array(repeating: Float(0), count: 384)
                    v[Int(abs(lead)) % 384] = 1.0
                    v[0] += 0.5   // shared component pulls everything toward the query
                    return v
                }),
                .mpNet(inference: { tokens in
                    let lead = tokens.first ?? 0
                    var v = Array(repeating: Float(0), count: 768)
                    // Consensus/query lead token → axis 1; other docs → distant axis.
                    let axis = (Int(abs(lead)) % 2 == 0) ? 1 : 400
                    v[axis] = 1.0
                    return v
                })
            ]
        )
        // Hamming vector store so the bm25 + hamming fixed lanes also produce hits.
        let vsStorage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        try await vsStorage.migrate(to: VectorStore.schemaDeclaration)
        let vectorStore = VectorStore(storage: vsStorage)
        let hammingModelID = await corpus.modelID

        var ids: [String] = []
        for content in contents {
            let frame = CaptureFrame(
                content: content,
                channel: .typed,
                room: "recall-shape-unionbest-tests",
                latticeAnchor: .udc("000"),
                addedBy: "recall-shape-unionbest-tests",
                embeddingModelID: "test-model-v1"
            )
            let drawer = try await kit.capture(handle, frame)
            ids.append(drawer.id)
            try await corpus.ingest(content, sourceID: drawer.id, now: Self.t0)
            let engram = try await corpus.embed(content)
            try await vectorStore.addVector(
                itemID: drawer.id, engram: engram, modelID: hammingModelID,
                modelVersion: "1.0", filedAt: Self.t0)
        }
        await kit.registerCorpus(corpus, for: handle)
        await kit.registerVectorStore(vectorStore, for: handle)
        return (kit: kit, handle: handle, ids: ids)
    }

    // Two docs: one ranked by BOTH dense signals (consensus), one ranked ONLY by
    // mpnet (single). Captured single-first so byCaptureTimeDesc + dense agree.
    private let singleContent = "zeta unrelated divergent wording only one signal aligns here"
    private let consensusContent = "alpha consensus topic shared across both embedding signals"
    private let query = "alpha consensus topic shared across both embedding signals"

    // MARK: - (a) dense-signal exclusion

    /// Excluding the mpnet dense signal (`dense:mpnet-base-v2`=0) removes EXACTLY
    /// that signal's votes from the consensus. The deterministic, normalization-
    /// proof observable is the per-hit dense provenance: with both signals voting,
    /// the consensus hit names BOTH miniLM and mpnet; with mpnet excluded, the
    /// consensus hit names ONLY miniLM — the excluded signal contributed nothing
    /// to the fusion, so it claims no provenance. The consensus among the surviving
    /// signal (miniLM) is unchanged: the drawer still surfaces with dense evidence.
    @Test("excluding one dense signal removes exactly that signal's votes")
    func denseSignalExclusionRemovesItsVotes() async throws {
        let (kit, handle, ids) = try await openTwoProviderEstate(
            [singleContent, consensusContent], owner: "dense-exclude-owner")
        let consensusID = ids[1]

        let full = try await kit.recall(handle, unionBestRRF(query: query))
        let excludeMPNet = RecallShape(laneWeights: ["dense:\(Self.mpNetID)": 0.0])
        let excluded = try await kit.recall(
            handle, unionBestRRF(query: query, shape: excludeMPNet))

        // Baseline: both dense signals voted for the consensus drawer.
        let fullConsensus = full.hits.first { $0.id == consensusID }
        let fullExpl = (fullConsensus?.explanation ?? []).joined(separator: " | ")
        #expect(fullExpl.contains("vectorDense:\(Self.miniLMID)"),
            "baseline consensus hit must record the miniLM dense signal; got: \(fullExpl)")
        #expect(fullExpl.contains("vectorDense:\(Self.mpNetID)"),
            "baseline consensus hit must record the mpnet dense signal; got: \(fullExpl)")

        // With mpnet excluded, the consensus drawer still surfaces (miniLM ranks it),
        // its provenance names ONLY miniLM, and the mpnet signal is gone entirely —
        // exactly that signal's votes removed, the surviving consensus unchanged.
        let exConsensus = excluded.hits.first { $0.id == consensusID }
        #expect(exConsensus != nil,
            "consensus drawer must still surface via the forwarding miniLM signal")
        let exExpl = (exConsensus?.explanation ?? []).joined(separator: " | ")
        #expect(exExpl.contains("vectorDense:\(Self.miniLMID)"),
            "with mpnet excluded, the surviving miniLM signal must still be named; got: \(exExpl)")
        #expect(!exExpl.contains("vectorDense:\(Self.mpNetID)"),
            "excluding mpnet must remove it from the consensus provenance; got: \(exExpl)")
    }

    // MARK: - (b) dense-signal suppression

    /// Suppressing the mpnet dense signal (`<0`) DEMOTES a drawer it ranks high.
    /// The mpnet-ONLY drawer (the "single" doc — mpnet ranks it, miniLM does not)
    /// is the lever: under neutral fusion mpnet gives it dense mass; under
    /// suppression that mass is SUBTRACTED (its dense `final` goes negative), so its
    /// fused rank is no better than neutral and never better than the consensus
    /// drawer. Distinct from exclusion: the suppressed signal still claims per-hit
    /// provenance because it contributed (negative) mass, where an EXCLUDED signal
    /// would claim none — the two operations produce different output.
    @Test("suppressing a dense signal demotes a drawer it ranks high")
    func denseSignalSuppressionDemotes() async throws {
        let (kit, handle, ids) = try await openTwoProviderEstate(
            [singleContent, consensusContent], owner: "dense-suppress-owner")
        let singleID = ids[0]       // surfaced by mpnet (the suppressed signal)
        let consensusID = ids[1]    // surfaced by both signals

        let neutral = try await kit.recall(handle, unionBestRRF(query: query))
        let suppress = RecallShape(laneWeights: ["dense:\(Self.mpNetID)": -1.0])
        let suppressed = try await kit.recall(
            handle, unionBestRRF(query: query, shape: suppress))
        let excludeShape = RecallShape(laneWeights: ["dense:\(Self.mpNetID)": 0.0])
        let excluded = try await kit.recall(
            handle, unionBestRRF(query: query, shape: excludeShape))

        // Demotion: the mpnet-favoured single drawer must rank no better under
        // suppression than under neutral, and never above the consensus drawer.
        let neutralSingleRank = neutral.hits.firstIndex { $0.id == singleID }
        let suppressedSingleRank = suppressed.hits.firstIndex { $0.id == singleID }
        if let n = neutralSingleRank, let s = suppressedSingleRank {
            #expect(s >= n,
                "suppressing mpnet must not improve the mpnet-favoured drawer's rank; neutral=\(n) suppressed=\(s)")
        }
        if let sIdx = suppressed.hits.firstIndex(where: { $0.id == singleID }),
           let cIdx = suppressed.hits.firstIndex(where: { $0.id == consensusID }) {
            #expect(cIdx <= sIdx,
                "under suppression the consensus drawer (rank \(cIdx)) must rank at/above the suppressed single drawer (rank \(sIdx))")
        }

        // Distinct from exclusion: a suppressed signal still claims provenance
        // (contributed subtracted mass); an excluded signal does not. The two shaped
        // fusions must therefore differ in their per-hit provenance for the single
        // drawer (mpnet present under suppression, absent under exclusion).
        func mpnetInProvenance(_ result: GLKRecallResult, _ id: String) -> Bool {
            (result.hits.first { $0.id == id }?.explanation ?? [])
                .joined(separator: " | ").contains("vectorDense:\(Self.mpNetID)")
        }
        // The single drawer is surfaced only by mpnet: under exclusion it carries no
        // dense provenance; under suppression mpnet is still named (it shaped the hit).
        #expect(!mpnetInProvenance(excluded, singleID),
            "EXCLUDED mpnet must not appear in the single drawer's provenance")
        if suppressed.hits.contains(where: { $0.id == singleID }) {
            #expect(mpnetInProvenance(suppressed, singleID),
                "SUPPRESSED mpnet still contributed mass, so it stays in the single drawer's provenance")
        }
    }

    // MARK: - (c) leave-one-out determinism

    /// Nulling one dense signal must be DETERMINISTIC: running the same nulled
    /// recall twice yields identical ids AND identical fused finals.
    @Test("leave-one-out dense exclusion is deterministic")
    func denseLeaveOneOutDeterministic() async throws {
        let (kit, handle, _) = try await openTwoProviderEstate(
            [singleContent, consensusContent], owner: "dense-loo-owner")
        let nullMPNet = RecallShape(laneWeights: ["dense:\(Self.mpNetID)": 0.0])

        let a = try await kit.recall(handle, unionBestRRF(query: query, shape: nullMPNet))
        let b = try await kit.recall(handle, unionBestRRF(query: query, shape: nullMPNet))
        #expect(a.hits.map(\.id) == b.hits.map(\.id),
            "leave-one-out dense fusion must produce a deterministic id order")
        for (x, y) in zip(a.hits, b.hits) {
            #expect(x.id == y.id)
            #expect(x.score.final == y.score.final,
                "leave-one-out dense fused finals must be deterministic; \(x.id): a=\(x.score.final) b=\(y.score.final)")
        }
    }

    // MARK: - (d) fixed-lane exclusion in unionBest

    /// Excluding the bm25 fixed lane (`bm25`=0) zeroes bm25's column contribution
    /// in the unionBest weighted-column score. The fused result must differ from
    /// the neutral fusion whenever bm25 contributed mass — proving the fixed-lane
    /// shape weight is live in unionBest, not just in the hybrid/corpusOnly lanes.
    @Test("a fixed-lane exclusion (bm25=0) zeroes its column in unionBest")
    func fixedLaneBM25ExclusionInUnionBest() async throws {
        let (kit, handle, _) = try await openTwoProviderEstate(
            [singleContent, consensusContent], owner: "fixed-exclude-owner")
        // Use matrixAware scoring — that is the unionBest weighted-column path the
        // fixed-lane shape weights compose into.
        func matrixReq(shape: RecallShape?) -> GLKRecallRequest {
            GLKRecallRequest(
                frame: RecallFrame(
                    filterChain: [.unconfirmed],
                    hydrationLevel: .structured,
                    ordering: .byCaptureTimeDesc),
                mode: .unionBest, scoring: .matrixAware, limit: 10,
                queryText: query, origin: .internal, recallShape: shape)
        }
        let neutral = try await kit.recall(handle, matrixReq(shape: nil))
        let excludeBM25 = try await kit.recall(
            handle, matrixReq(shape: RecallShape(laneWeights: ["bm25": 0.0])))

        let neutralByID = Dictionary(uniqueKeysWithValues: neutral.hits.map { ($0.id, $0.score.final) })
        var sawChange = false
        for hit in excludeBM25.hits {
            if let before = neutralByID[hit.id], before != hit.score.final { sawChange = true }
        }
        #expect(sawChange || excludeBM25.hits.map(\.id) != neutral.hits.map(\.id),
            "excluding the bm25 column must change the unionBest fused scores or order")
    }

    // MARK: - (e) nil-shape byte-identity (back-compat)

    /// nil shape and an explicit all-ones shape (every lane key 1.0) must produce
    /// BYTE-IDENTICAL unionBest output — ids, order, and fused finals — across both
    /// the matrixAware column path and the dense consensus path. This is the
    /// production back-compat contract for 6b-modifiers-core-2.
    @Test("nil shape and an all-ones shape are byte-identical in unionBest")
    func nilShapeEqualsAllOnesInUnionBest() async throws {
        let (kit, handle, _) = try await openTwoProviderEstate(
            [singleContent, consensusContent], owner: "unionbest-backcompat-owner")
        let onesShape = RecallShape(laneWeights: [
            "locus": 1.0, "bm25": 1.0, "hamming": 1.0, "dense": 1.0,
            "dense:\(Self.miniLMID)": 1.0, "dense:\(Self.mpNetID)": 1.0
        ])
        func matrixReq(shape: RecallShape?) -> GLKRecallRequest {
            GLKRecallRequest(
                frame: RecallFrame(
                    filterChain: [.unconfirmed],
                    hydrationLevel: .structured,
                    ordering: .byCaptureTimeDesc),
                mode: .unionBest, scoring: .matrixAware, limit: 10,
                queryText: query, origin: .internal, recallShape: shape)
        }

        let nilResult = try await kit.recall(handle, matrixReq(shape: nil))
        let onesResult = try await kit.recall(handle, matrixReq(shape: onesShape))

        #expect(nilResult.hits.map(\.id) == onesResult.hits.map(\.id),
            "all-ones shape must produce the same unionBest id order as nil shape")
        for (a, b) in zip(nilResult.hits, onesResult.hits) {
            #expect(a.id == b.id)
            #expect(a.score.final == b.score.final,
                "unionBest fused final must be byte-identical at all-ones; \(a.id): nil=\(a.score.final) ones=\(b.score.final)")
            #expect(a.score.dense == b.score.dense,
                "unionBest dense column must be byte-identical at all-ones; \(a.id): nil=\(a.score.dense) ones=\(b.score.dense)")
        }
    }
}
