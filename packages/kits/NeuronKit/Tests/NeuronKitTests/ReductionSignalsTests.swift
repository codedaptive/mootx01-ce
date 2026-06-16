// ReductionSignalsTests.swift
//
// Unit tests for each reduction signal component and for the composition fold.
// Every signal is a pure, deterministic per-candidate scorer in [0, 1]; these
// tests fix the math against hand-built fixtures (no estate, no clock) so a
// Rust port can mirror identical numbers, and prove a known composition ranks a
// planted target correctly over its near-duplicate distractors.

import Testing
import Foundation
import GeniusLocusKit
@testable import NeuronKit

// `.serialized`: the reduceLate tests track hydration by mutating a captured
// `var` from inside the async hydrate closure; serial execution keeps that
// tracking race-free under Swift Testing's parallel runner.
@Suite("ReductionSignalsTests", .serialized)
struct ReductionSignalsTests {

    /// Build a score vector carrying just the fields a given signal reads.
    private func vec(
        bm25: Float = 0, vector: Float = 0, coOccurrence: Float = 0,
        hamming: Int = RecallScoreVector.noHammingDistance
    ) -> RecallScoreVector {
        RecallScoreVector(
            locus: 0, bm25: bm25, vector: vector, fieldFit: 0,
            coOccurrence: coOccurrence, temporal: 0, graph: 0, preference: 0,
            redundancyPenalty: 0, final: 0, hammingDistance: hamming)
    }

    private func candidate(
        id: String, content: String = "", udc: String = "",
        bm25: Float = 0, vector: Float = 0, coOccurrence: Float = 0,
        hamming: Int = RecallScoreVector.noHammingDistance, coarseRank: Int = 0,
        eventTime: Date? = nil, isCurrentlyBelieved: Bool = true
    ) -> NeuronKit.ReductionCandidate {
        NeuronKit.ReductionCandidate(
            id: id, content: content, room: "r",
            score: vec(bm25: bm25, vector: vector, coOccurrence: coOccurrence, hamming: hamming),
            udcCode: udc, udcFacets: nil, coarseRank: coarseRank,
            eventTime: eventTime, isCurrentlyBelieved: isCurrentlyBelieved)
    }

    // MARK: - hamming

    @Test("hamming similarity: distance 0 → 1, 256 → 0, sentinel → 0")
    func hammingSimilarity() {
        #expect(NeuronKit.hammingSimilarity(0) == 1.0)
        #expect(NeuronKit.hammingSimilarity(256) == 0.0)
        #expect(NeuronKit.hammingSimilarity(128) == 0.5)
        // sentinel (not a vector-lane hit) → 0
        #expect(NeuronKit.hammingSimilarity(RecallScoreVector.noHammingDistance) == 0.0)
    }

    @Test("hamming signal ranks the closer engram higher")
    func hammingSignalOrders() {
        let q = NeuronKit.ReductionQuery(text: "anything")
        let near = candidate(id: "near", hamming: 10)
        let far = candidate(id: "far", hamming: 200)
        let sNear = NeuronKit.reductionScore(.hamming, query: q, candidate: near)
        let sFar = NeuronKit.reductionScore(.hamming, query: q, candidate: far)
        #expect(sNear > sFar)
    }

    // MARK: - matrix / bm25 / vector

    @Test("matrix signal reads co-occurrence, clamped to [0,1]")
    func matrixSignal() {
        let q = NeuronKit.ReductionQuery(text: "x")
        // Float→Double widening of 0.7 is not bit-exact; compare within tolerance.
        #expect(abs(NeuronKit.reductionScore(.matrix, query: q, candidate: candidate(id: "a", coOccurrence: 0.7)) - 0.7) < 1e-6)
        // out-of-range clamps
        #expect(NeuronKit.reductionScore(.matrix, query: q, candidate: candidate(id: "b", coOccurrence: 1.5)) == 1.0)
    }

    @Test("bm25 signal squashes monotonically into [0,1)")
    func bm25Signal() {
        let q = NeuronKit.ReductionQuery(text: "x")
        let small = NeuronKit.reductionScore(.bm25, query: q, candidate: candidate(id: "a", bm25: 1))
        let big = NeuronKit.reductionScore(.bm25, query: q, candidate: candidate(id: "b", bm25: 10))
        #expect(small == 0.5)               // 1/(1+1)
        #expect(big > small && big < 1.0)
        #expect(NeuronKit.reductionScore(.bm25, query: q, candidate: candidate(id: "c", bm25: 0)) == 0)
    }

    @Test("vector signal passes the normalized similarity through")
    func vectorSignal() {
        let q = NeuronKit.ReductionQuery(text: "x")
        #expect(abs(NeuronKit.reductionScore(.vector, query: q, candidate: candidate(id: "a", vector: 0.8)) - 0.8) < 1e-6)
    }

    // MARK: - lattice

    @Test("lattice proximity: exact match 1, shared prefix partial, unanchored neutral")
    func latticeProximity() {
        // exact
        #expect(NeuronKit.latticeProximity(queryCode: "547.1", candidateCode: "547.1") == 1.0)
        // shared prefix "547" over longer "547.12" (6 chars) = 3/6 = 0.5
        #expect(NeuronKit.latticeProximity(queryCode: "547", candidateCode: "547.12") == 0.5)
        // no shared prefix
        #expect(NeuronKit.latticeProximity(queryCode: "547", candidateCode: "812") == 0.0)
        // unanchored query → neutral
        #expect(NeuronKit.latticeProximity(queryCode: "", candidateCode: "547") == 0.5)
        // anchored query, unanchored candidate → far
        #expect(NeuronKit.latticeProximity(queryCode: "547", candidateCode: "") == 0.0)
    }

    @Test("lattice signal reads the candidate UDC against the query region")
    func latticeSignal() {
        let q = NeuronKit.ReductionQuery(text: "organic chemistry", udcCode: "547")
        let near = candidate(id: "near", udc: "547.1")
        let far = candidate(id: "far", udc: "330")
        #expect(NeuronKit.reductionScore(.lattice, query: q, candidate: near)
                > NeuronKit.reductionScore(.lattice, query: q, candidate: far))
    }

    // MARK: - tokenExact (the 46 vs 11 separator)

    @Test("tokenExact: only the candidate carrying the queried number scores")
    func tokenExactDiscriminates() {
        let q = NeuronKit.ReductionQuery(text: "the indemnity was 46 million marks")
        let right = candidate(id: "right", content: "the indemnity was 46 million marks")
        let wrong = candidate(id: "wrong", content: "the indemnity was 11 million marks")
        let sRight = NeuronKit.reductionScore(.tokenExact, query: q, candidate: right)
        let sWrong = NeuronKit.reductionScore(.tokenExact, query: q, candidate: wrong)
        #expect(sRight == 1.0)   // the only distinctive token "46" is present
        #expect(sWrong == 0.0)   // "46" absent
    }

    @Test("tokenExact abstains (0) when the query names no distinctive token")
    func tokenExactAbstains() {
        let q = NeuronKit.ReductionQuery(text: "the indemnity was paid")
        let c = candidate(id: "c", content: "the indemnity was paid in full")
        #expect(NeuronKit.reductionScore(.tokenExact, query: q, candidate: c) == 0.0)
    }

    // MARK: - text

    @Test("text signal reuses queryPrecision and ranks the content-matched candidate higher")
    func textSignal() {
        let q = NeuronKit.ReductionQuery(text: "Helsinki division revenue 46 million")
        let right = candidate(id: "right", content: "quarterly revenue for the Helsinki division was 46 million euros")
        let wrong = candidate(id: "wrong", content: "quarterly revenue for the Helsinki division was 11 million euros")
        #expect(NeuronKit.reductionScore(.text, query: q, candidate: right)
                > NeuronKit.reductionScore(.text, query: q, candidate: wrong))
    }

    // MARK: - T3 temporal (current over superseded)

    @Test("temporalText: a 'current' marker beats a 'superseded' marker; unmarked neutral")
    func temporalTextDiscriminates() {
        let q = NeuronKit.ReductionQuery(text: "the tariff rate")
        let current = candidate(id: "cur", content: "the tariff rate is 12% (current as of 2025)")
        let stale = candidate(id: "old", content: "the tariff rate is 9% (superseded; recorded 2011)")
        let plain = candidate(id: "plain", content: "the tariff rate is set by statute")
        let sCur = NeuronKit.reductionScore(.temporalText, query: q, candidate: current)
        let sOld = NeuronKit.reductionScore(.temporalText, query: q, candidate: stale)
        let sPlain = NeuronKit.reductionScore(.temporalText, query: q, candidate: plain)
        #expect(sCur == 1.0)
        #expect(sOld == 0.0)
        #expect(sPlain == 0.5)
        #expect(sCur > sOld)
    }

    @Test("temporalState: a currently-believed record beats a superseded one (body-free)")
    func temporalStateDiscriminates() {
        let q = NeuronKit.ReductionQuery(text: "anything")
        let live = candidate(id: "live", isCurrentlyBelieved: true)
        let dead = candidate(id: "dead", isCurrentlyBelieved: false)
        #expect(NeuronKit.reductionScore(.temporalState, query: q, candidate: live) == 1.0)
        #expect(NeuronKit.reductionScore(.temporalState, query: q, candidate: dead) == 0.0)
    }

    @Test("text+temporal composition ranks the current version over its superseded near-duplicate")
    func temporalCompositionRanksCurrentFirst() {
        // The T3 shape: same subject+attribute, one current, the rest superseded
        // earlier versions. Content words are near-identical; only the currency
        // marker separates them. The superseded distractor sits FIRST in coarse
        // order (worst case) — the temporal term must lift the current one.
        let q = NeuronKit.ReductionQuery(text: "the indemnity was set at 46 million marks")
        let pool = [
            candidate(id: "old1", content: "the indemnity was set at 31 million marks (superseded; recorded 2009)", coarseRank: 0),
            candidate(id: "old2", content: "the indemnity was set at 22 million marks (superseded; recorded 2014)", coarseRank: 1),
            candidate(id: "cur",  content: "the indemnity was set at 46 million marks (current as of 2025)", coarseRank: 2),
        ]
        let comp = NeuronKit.CompositionGrid.named("text+temporal")
        let ranked = NeuronKit.reduce(composition: comp, query: q, candidates: pool, limit: 10)
        #expect(ranked.first?.id == "cur", "the current version must rank first over superseded near-duplicates")
    }

    // MARK: - T4 split-fact assembly (partner pulled in)

    @Test("referenceCodes extracts REF-NNNN tokens case-insensitively")
    func referenceCodeExtraction() {
        #expect(NeuronKit.referenceCodes(in: "see reference REF-0042 for the value") == ["ref-0042"])
        #expect(NeuronKit.referenceCodes(in: "Reference REF-1234: the rate is 9%") == ["ref-1234"])
        #expect(NeuronKit.referenceCodes(in: "no codes here") == [])
        // a record naming several codes links to each.
        #expect(NeuronKit.referenceCodes(in: "REF-0001 and ref-0002") == ["ref-0001", "ref-0002"])
    }

    @Test("assembly expansion pulls a split partner up next to the record that references it")
    func assemblyPullsPartner() {
        // The needle half ranks (it matches the query); its partner — keyed by
        // the same REF code, holding the value — sits LAST in the pool with no
        // query overlap. A pure re-rank could never surface it; assembly must
        // pull it up adjacent to the needle.
        let q = NeuronKit.ReductionQuery(text: "what is the assessment under the city's reference")
        let pool = [
            candidate(id: "needle",  content: "the city records its assessment under reference REF-0007; see the matching reference entry for the value", coarseRank: 0),
            candidate(id: "miss1",   content: "Reference REF-9991: the assessment is 14%.", coarseRank: 1),
            candidate(id: "miss2",   content: "Reference REF-9992: the assessment is 27%.", coarseRank: 2),
            candidate(id: "partner", content: "Reference REF-0007: the assessment is 46%.", coarseRank: 3),
        ]
        let comp = NeuronKit.CompositionGrid.named("text+assembly")
        let ranked = NeuronKit.reduce(composition: comp, query: q, candidates: pool, limit: 4)
        let ids = ranked.map(\.id)
        // The partner is co-surfaced, immediately following its needle.
        #expect(ids.contains("partner"), "the split partner must be pulled into the bounded set")
        if let ni = ids.firstIndex(of: "needle"), let pi = ids.firstIndex(of: "partner") {
            #expect(pi == ni + 1, "the partner must immediately follow the record that references it")
        } else {
            Issue.record("needle and partner must both be present")
        }
    }

    @Test("assembly expansion brings a partner that would fall outside the limit into the bounded set")
    func assemblyPromotesPartnerInsideLimit() {
        let q = NeuronKit.ReductionQuery(text: "the reference for the city assessment")
        // needle ranks first; partner is last and would be cut by limit 2 — the
        // expansion must promote it so the split fact is complete within the set.
        let pool = [
            candidate(id: "needle",  content: "the city files its assessment under reference REF-0007; see the reference entry", coarseRank: 0),
            candidate(id: "noise1",  content: "an unrelated note about budgets", coarseRank: 1),
            candidate(id: "noise2",  content: "another unrelated municipal note", coarseRank: 2),
            candidate(id: "partner", content: "Reference REF-0007: the assessment is 46%.", coarseRank: 3),
        ]
        let comp = NeuronKit.CompositionGrid.named("text+assembly")
        let ranked = NeuronKit.reduce(composition: comp, query: q, candidates: pool, limit: 2).map(\.id)
        #expect(ranked == ["needle", "partner"], "assembly promotes the partner into the limited window")
    }

    // MARK: - composition fold

    @Test("hamming+tokenExact composition ranks the planted target first")
    func compositionRanksTarget() {
        let q = NeuronKit.ReductionQuery(text: "the indemnity was 46 million marks")
        // Three near-duplicates; the 46 target is NOT first in coarse order and
        // has a slightly worse hamming than a distractor — only the combined
        // composition (with tokenExact) lifts it to rank 1.
        let pool = [
            candidate(id: "d11", content: "the indemnity was 11 million marks", hamming: 8, coarseRank: 0),
            candidate(id: "d23", content: "the indemnity was 23 million marks", hamming: 12, coarseRank: 1),
            candidate(id: "t46", content: "the indemnity was 46 million marks", hamming: 14, coarseRank: 2),
        ]
        let comp = NeuronKit.CompositionGrid.named("hamming+tokenExact")
        let ranked = NeuronKit.reduce(composition: comp, query: q, candidates: pool, limit: 10)
        #expect(ranked.first?.id == "t46", "the queried-figure target must rank first")
    }

    @Test("bounded reduce never prunes below the coarse pool, only re-orders + truncates")
    func boundedReduce() {
        let q = NeuronKit.ReductionQuery(text: "anything 46")
        let pool = (0..<5).map { candidate(id: "c\($0)", content: "filler \($0)", coarseRank: $0) }
        let comp = NeuronKit.CompositionGrid.named("text")
        // limit larger than pool returns the whole pool (no shrink).
        #expect(NeuronKit.reduce(composition: comp, query: q, candidates: pool, limit: 100).count == 5)
        // limit smaller truncates to limit.
        #expect(NeuronKit.reduce(composition: comp, query: q, candidates: pool, limit: 2).count == 2)
    }

    @Test("reduce is deterministic: identical inputs → identical order across runs")
    func reduceDeterministic() {
        let q = NeuronKit.ReductionQuery(text: "the bridge was 350 metres long")
        let pool = [
            candidate(id: "a", content: "the bridge over the river was 200 metres long", hamming: 20, coarseRank: 0),
            candidate(id: "b", content: "the bridge over the river was 350 metres long", hamming: 18, coarseRank: 1),
            candidate(id: "c", content: "the bridge over the river was 90 metres long", hamming: 22, coarseRank: 2),
        ]
        let comp = NeuronKit.CompositionGrid.named("weighted-all")
        let first = NeuronKit.reduce(composition: comp, query: q, candidates: pool, limit: 10).map(\.id)
        let second = NeuronKit.reduce(composition: comp, query: q, candidates: pool, limit: 10).map(\.id)
        #expect(first == second)
    }

    @Test("the grid is non-empty and every name resolves")
    func gridIntegrity() {
        #expect(!NeuronKit.CompositionGrid.all.isEmpty)
        for name in NeuronKit.CompositionGrid.names {
            #expect(NeuronKit.CompositionGrid.named(name).name == name)
        }
        // unknown name degrades to the default.
        #expect(NeuronKit.CompositionGrid.named("nonsense").name == NeuronKit.CompositionGrid.defaultName)
        #expect(NeuronKit.CompositionGrid.named(nil).name == NeuronKit.CompositionGrid.defaultName)
    }

    // MARK: - needsContent classification

    @Test("needsContent: text/tokenExact/mmr/temporalText/assembly need a body; the dense signals do not")
    func needsContentClassification() {
        #expect(NeuronKit.ReductionSignal.text.needsContent)
        #expect(NeuronKit.ReductionSignal.tokenExact.needsContent)
        #expect(NeuronKit.ReductionSignal.mmr.needsContent)
        #expect(NeuronKit.ReductionSignal.temporalText.needsContent)
        #expect(NeuronKit.ReductionSignal.assembly.needsContent)
        #expect(!NeuronKit.ReductionSignal.hamming.needsContent)
        #expect(!NeuronKit.ReductionSignal.matrix.needsContent)
        #expect(!NeuronKit.ReductionSignal.lattice.needsContent)
        #expect(!NeuronKit.ReductionSignal.bm25.needsContent)
        #expect(!NeuronKit.ReductionSignal.vector.needsContent)
        // temporalState reads only body-free structured columns.
        #expect(!NeuronKit.ReductionSignal.temporalState.needsContent)
    }

    @Test("assembly is set-level (an expansion, not a per-candidate score)")
    func assemblyIsSetLevel() {
        #expect(NeuronKit.ReductionSignal.assembly.isSetLevel)
        #expect(NeuronKit.ReductionSignal.mmr.isSetLevel)
        #expect(!NeuronKit.ReductionSignal.temporalState.isSetLevel)
        #expect(!NeuronKit.ReductionSignal.temporalText.isSetLevel)
    }

    // MARK: - reduceLate (narrow-then-hydrate)

    /// A pure-dense composition (`hamming`) SELECTS the top-k body-free over the
    /// wide pool (the latency win) and returns the SAME ranking as `reduce`, but
    /// the OUTPUT lane MATERIALIZES the final top-k: only the ≈`limit` selected
    /// records are hydrated, never the wide pool. The two-lane principle.
    @Test("reduceLate: pure-dense selects body-free, hydrates only the final top-k")
    func reduceLatePureDenseHydratesFinalTopK() async throws {
        let q = NeuronKit.ReductionQuery(text: "anything")
        // Bodies are EMPTY in the pool (body-free), as the GLK structured load
        // delivers them.
        let pool = [
            candidate(id: "near", content: "", hamming: 10, coarseRank: 0),
            candidate(id: "mid",  content: "", hamming: 90, coarseRank: 1),
            candidate(id: "far",  content: "", hamming: 200, coarseRank: 2),
        ]
        let comp = NeuronKit.CompositionGrid.named("hamming")
        var hydratedIDs: [String] = []
        let late = try await NeuronKit.reduceLate(
            composition: comp, query: q, candidates: pool, limit: 2,
            hydrate: { ids in
                hydratedIDs.append(contentsOf: ids)
                return Dictionary(uniqueKeysWithValues: ids.map { ($0, "body of \($0)") })
            }
        )
        let lateIDs = late.map(\.id)
        // Ranking matches the eager reduce over the same pool.
        let eager = NeuronKit.reduce(composition: comp, query: q, candidates: pool, limit: 2).map(\.id)
        #expect(lateIDs == eager)
        #expect(lateIDs == ["near", "mid"])
        // OUTPUT lane: only the final top-k (the 2 selected) are hydrated — NOT
        // the wide pool ("far" never gets a body request). The latency win holds.
        #expect(Set(hydratedIDs) == ["near", "mid"],
                "only the final top-k is hydrated, got \(hydratedIDs)")
        #expect(!hydratedIDs.contains("far"), "the unselected wide-pool body must not be read")
    }

    /// P0-5 site 10 (fail-closed hydration): a hydrate failure must PROPAGATE
    /// out of `reduceLate`, not collapse to an empty body map. Before the fix
    /// (CognitionKit PreciseRecall swallowed `try? ... ?? [:]`) a hydration
    /// fault produced survivors with empty content — indistinguishable from a
    /// genuinely empty body. A precise recall that cannot hydrate its survivors
    /// is a FAILED recall, not an empty one.
    ///
    /// FORCE-TEST: inject a throwing hydrate closure and assert the error
    /// surfaces rather than being absorbed into body-free results.
    @Test("reduceLate: a hydrate failure propagates, never empty-content survivors")
    func reduceLateHydrateFailurePropagates() async {
        struct HydrateFault: Error {}
        let q = NeuronKit.ReductionQuery(text: "anything")
        let pool = [
            candidate(id: "a", content: "", hamming: 10, coarseRank: 0),
            candidate(id: "b", content: "", hamming: 90, coarseRank: 1),
        ]
        let comp = NeuronKit.CompositionGrid.named("hamming")
        await #expect(throws: HydrateFault.self) {
            _ = try await NeuronKit.reduceLate(
                composition: comp, query: q, candidates: pool, limit: 2,
                hydrate: { _ in throw HydrateFault() }
            )
        }
    }

    /// REGRESSION (dreamed-ablation found@k 0.00 bug): a DENSE-ONLY composition
    /// must return its final top-k with NON-EMPTY content. Before the two-lane
    /// fix, `reduceLate` selected the top-k body-free and returned them WITHOUT
    /// hydrating, so every dense-only composition (`bm25`, `hamming`,
    /// `weighted-all`, …) emitted empty-content drawers the gauntlet could not
    /// match — found@k collapsed to 0.00. This pins the fix: the materialized
    /// output carries bodies and the right hit ranks first.
    @Test("reduceLate: dense-only composition returns final top-k WITH content (regression)")
    func reduceLateDenseOnlyMaterializesContent() async throws {
        let q = NeuronKit.ReductionQuery(text: "anything")
        // Body-free pool: the true target (closest hamming) plus distractors.
        let pool = [
            candidate(id: "hit",   content: "", hamming: 5,   coarseRank: 0),
            candidate(id: "near",  content: "", hamming: 40,  coarseRank: 1),
            candidate(id: "far",   content: "", hamming: 220, coarseRank: 2),
        ]
        // The body store the OUTPUT lane materializes from.
        let bodies = [
            "hit":  "the exact answer the gauntlet planted",
            "near": "a near-duplicate distractor",
            "far":  "an unrelated record",
        ]
        let comp = NeuronKit.CompositionGrid.named("hamming")
        let result = try await NeuronKit.reduceLate(
            composition: comp, query: q, candidates: pool, limit: 1,
            hydrate: { ids in bodies.filter { ids.contains($0.key) } }
        )
        // The closest-hamming record ranks first AND carries its hydrated body.
        #expect(result.first?.id == "hit", "the dense-closest hit must rank first")
        #expect(result.first?.content == bodies["hit"],
                "the final top-k must be MATERIALIZED — non-empty content, not the body-free selection lane")
        #expect(result.first?.content.isEmpty == false,
                "a dense-only composition that returns empty content is the found@k 0.00 regression")
    }

    /// A mixed composition (`hamming+tokenExact`) narrows on the dense signal
    /// first, then hydrates ONLY the bounded survivor set — never the whole
    /// wide pool — and the content term still discriminates the survivors.
    @Test("reduceLate: mixed composition hydrates only the survivors, not the wide pool")
    func reduceLateMixedHydratesSurvivorsOnly() async throws {
        let q = NeuronKit.ReductionQuery(text: "bridge 350 metres")
        // A wide pool: 20 candidates. The dense (hamming) signal favors the
        // first few; the true target carries the distinctive token "350".
        var pool: [NeuronKit.ReductionCandidate] = []
        for i in 0..<20 {
            // Closer hamming for low i; the planted target at i==1 also matches
            // the token. Bodies are EMPTY in the pool (filled by hydrate).
            pool.append(candidate(id: "d\(i)", content: "", hamming: 10 + i * 5, coarseRank: i))
        }
        // The body store the hydrator draws from — only survivors should be read.
        let bodies: [String: String] = Dictionary(uniqueKeysWithValues: (0..<20).map { i in
            ("d\(i)", i == 1 ? "the bridge over the river was 350 metres long"
                             : "an unrelated note number \(i)")
        })
        let comp = NeuronKit.CompositionGrid.named("hamming+tokenExact")
        var hydratedIDs: Set<String> = []
        let result = try await NeuronKit.reduceLate(
            composition: comp, query: q, candidates: pool, limit: 2,
            survivorMultiple: 4,
            hydrate: { ids in
                for id in ids { hydratedIDs.insert(id) }
                return bodies.filter { ids.contains($0.key) }
            }
        )
        // survivorMultiple 4 × limit 2 = 8 survivors hydrated, NOT all 20.
        #expect(hydratedIDs.count == 8, "only the bounded survivor set is hydrated, got \(hydratedIDs.count)")
        #expect(hydratedIDs.count < pool.count, "the wide pool's bodies must not all be read")
        // The token-matching target (d1) is in the survivor window and the
        // tokenExact term lifts it; it must be returned.
        #expect(result.map(\.id).contains("d1"), "the token-matching survivor must be returned")
        // The returned survivors carry their hydrated bodies.
        #expect(result.first(where: { $0.id == "d1" })?.content.contains("350") == true)
    }

    /// A content-only composition (the default `text`) has no dense term to
    /// narrow on, so reduceLate hydrates the whole pool and is bit-identical to
    /// `reduce` — the default recipe is unchanged (no regression).
    @Test("reduceLate: content-only default matches eager reduce exactly")
    func reduceLateContentOnlyEquivalentToReduce() async throws {
        let q = NeuronKit.ReductionQuery(text: "versailles 1715")
        let bodies = [
            "a": "the palace of versailles was completed in 1715",
            "b": "a garden in versailles, unrelated to dates",
            "c": "versailles is a commune; the year 1715 is elsewhere",
        ]
        // Eager pool: bodies present (as a fully-hydrated reduce would see).
        let eagerPool = [
            candidate(id: "a", content: bodies["a"]!, coarseRank: 0),
            candidate(id: "b", content: bodies["b"]!, coarseRank: 1),
            candidate(id: "c", content: bodies["c"]!, coarseRank: 2),
        ]
        // Body-free pool: same candidates, empty bodies, hydrated on demand.
        let freePool = [
            candidate(id: "a", content: "", coarseRank: 0),
            candidate(id: "b", content: "", coarseRank: 1),
            candidate(id: "c", content: "", coarseRank: 2),
        ]
        let comp = NeuronKit.CompositionGrid.named("text")
        let eager = NeuronKit.reduce(composition: comp, query: q, candidates: eagerPool, limit: 3).map(\.id)
        let late = try await NeuronKit.reduceLate(
            composition: comp, query: q, candidates: freePool, limit: 3,
            hydrate: { ids in bodies.filter { ids.contains($0.key) } }
        ).map(\.id)
        #expect(late == eager, "content-only reduceLate must match eager reduce")
    }
}
