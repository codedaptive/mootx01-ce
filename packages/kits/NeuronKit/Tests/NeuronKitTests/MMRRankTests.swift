// MMRRankTests.swift
//
// Conformance and edge-case tests for `mmrRank`, the standalone
// Maximal Marginal Relevance diversity rerank specified in
// NEURONKIT_SPEC § 4.1 step 4. The tests use fixed, hand-constructed
// `Engram` fingerprints (via `Engram(blocks:_:_:_:)`) so the MMR math
// is verifiable without an estate — the query is the all-zero engram,
// which makes Hamming distance-to-query equal to a candidate's bit
// popcount, and every relevance/similarity term is hand-computable.
//
// These tests are the Rust version's conformance contract too: the
// greedy selection order and the input-index tie-break documented
// here must reproduce bit-identically across versions.

import Testing
import Foundation
import EngramLib
@testable import NeuronKit

@Suite("mmrRank diversity rerank")
struct MMRRankTests {

    // MARK: - Fixtures
    //
    // Query = all-zero engram. distance(candidate, query) = popcount.
    //
    //   A: bits 0..<40  set  -> popcount 40, dist(A,Q)=40, rel=1-40/256=0.84375
    //   B: bits 0..<44  set  -> popcount 44, dist(B,Q)=44, rel=1-44/256=0.828125
    //                          B differs from A only in bits 40..43 -> dist(A,B)=4,
    //                          sim(A,B)=1-4/256=0.984375  (A and B near-duplicates)
    //   C: 80 bits in blocks 1..2, disjoint from A and B
    //                       -> popcount 80, dist(C,Q)=80, rel=1-80/256=0.6875
    //                          dist(C,A)=120 (disjoint), sim(C,A)=1-120/256=0.53125
    //
    // Hand-computed greedy MMR for lambda=0.7 over input order [A, B, C]:
    //   step 1 (nothing selected, maxSim=0): score = 0.7*rel
    //       A=0.590625, B=0.5796875, C=0.48125  -> pick A
    //   step 2 (selected={A}): score = 0.7*rel - 0.3*sim(x,A)
    //       B = 0.5796875 - 0.3*0.984375 = 0.284375
    //       C = 0.48125    - 0.3*0.53125  = 0.321875  -> pick C (diversity wins)
    //   step 3: pick B
    //   => MMR order [A, C, B], which differs from pure-relevance [A, B, C].

    /// Bits 0..<count set as a 64-bit block (count <= 64).
    private func lowBits(_ count: Int) -> UInt64 {
        count >= 64 ? ~UInt64(0) : (UInt64(1) << count) - 1
    }

    private func fingerprintA() -> Engram { Engram(blocks: lowBits(40), 0, 0, 0) }
    private func fingerprintB() -> Engram { Engram(blocks: lowBits(44), 0, 0, 0) }
    private func fingerprintC() -> Engram { Engram(blocks: 0, ~UInt64(0), lowBits(16), 0) }

    /// Candidates carry their fingerprint identity in `id` so the
    /// closure can map each Drawer back to its hand-built engram.
    private func candidates() -> [Drawer] {
        [makeDrawer(id: "A"), makeDrawer(id: "B"), makeDrawer(id: "C")]
    }

    /// The caller-supplied fingerprint derivation. In production the
    /// estate owner passes `EstateFingerprintFamilies.fingerprint(of:)`;
    /// here we map by id to the hand-built engrams above.
    private func fingerprint(_ d: Drawer) -> Engram {
        switch d.id {
        case "A": return fingerprintA()
        case "B": return fingerprintB()
        case "C": return fingerprintC()
        default: Issue.record("unexpected drawer id \(d.id)"); return Engram(blocks: 0, 0, 0, 0)
        }
    }

    private var query: Engram { Engram(blocks: 0, 0, 0, 0) }

    // MARK: - 1. Greedy selection order

    @Test("greedy selection order matches the MMR formula")
    func greedyOrderMatchesMMRFormula() {
        // lambda=0.7 picks A, then C (diversity beats B's marginally
        // higher relevance), then B. See the worked computation above.
        let out = mmrRank(
            candidates: candidates(),
            query: query,
            lambda: 0.7,
            k: 3,
            fingerprint: fingerprint
        )
        #expect(out.map(\.id) == ["A", "C", "B"])
    }

    // MARK: - 2. Lambda extremes

    @Test("lambda=1.0 yields pure-relevance order")
    func lambdaOneIsPureRelevanceOrder() {
        // lambda=1.0 zeroes the diversity term: order is closest-to-
        // query first. dist A=40 < B=44 < C=80 -> [A, B, C].
        let out = mmrRank(
            candidates: candidates(),
            query: query,
            lambda: 1.0,
            k: 3,
            fingerprint: fingerprint
        )
        #expect(out.map(\.id) == ["A", "B", "C"])
    }

    @Test("lambda=0.0 yields diversity-first order")
    func lambdaZeroIsDiversityFirst() {
        // lambda=0.0 zeroes the relevance term. Step 1 scores are all
        // 0 (no selection yet), so the input-index tie-break picks the
        // first candidate (A, also the most relevant). Step 2 maximises
        // distance from A: C (sim 0.53125) beats B (sim 0.984375).
        let out = mmrRank(
            candidates: candidates(),
            query: query,
            lambda: 0.0,
            k: 3,
            fingerprint: fingerprint
        )
        #expect(out.map(\.id) == ["A", "C", "B"])
    }

    // MARK: - 3. k truncation

    @Test("k less than count returns exactly k")
    func kLessThanCountReturnsExactlyK() {
        let out = mmrRank(
            candidates: candidates(),
            query: query,
            lambda: 0.7,
            k: 2,
            fingerprint: fingerprint
        )
        #expect(out.map(\.id) == ["A", "C"])
    }

    @Test("k >= count returns all candidates")
    func kGreaterThanOrEqualToCountReturnsAll() {
        let out = mmrRank(
            candidates: candidates(),
            query: query,
            lambda: 0.7,
            k: 99,
            fingerprint: fingerprint
        )
        #expect(out.map(\.id) == ["A", "C", "B"])
    }

    @Test("k=0 returns empty")
    func kZeroReturnsEmpty() {
        let out = mmrRank(
            candidates: candidates(),
            query: query,
            lambda: 0.7,
            k: 0,
            fingerprint: fingerprint
        )
        #expect(out.isEmpty)
    }

    @Test("negative k returns empty")
    func negativeKReturnsEmpty() {
        let out = mmrRank(
            candidates: candidates(),
            query: query,
            lambda: 0.7,
            k: -3,
            fingerprint: fingerprint
        )
        #expect(out.isEmpty)
    }

    // MARK: - 4. Empty candidates

    @Test("empty candidates returns empty")
    func emptyCandidatesReturnsEmpty() {
        let out = mmrRank(
            candidates: [],
            query: query,
            lambda: 0.7,
            k: 5,
            fingerprint: fingerprint
        )
        #expect(out.isEmpty)
    }

    // MARK: - 5. Determinism / tie-break

    @Test("two runs are bit-identical")
    func twoRunsAreBitIdentical() {
        let first = mmrRank(
            candidates: candidates(),
            query: query,
            lambda: 0.7,
            k: 3,
            fingerprint: fingerprint
        )
        let second = mmrRank(
            candidates: candidates(),
            query: query,
            lambda: 0.7,
            k: 3,
            fingerprint: fingerprint
        )
        #expect(first.map(\.id) == second.map(\.id))
    }

    @Test("equal scores break by input index ascending")
    func equalScoresBreakByInputIndexAscending() {
        // Three identical fingerprints: every relevance and similarity
        // term is equal, so every step is a tie. The input-index
        // tie-break must preserve input order exactly.
        let same = Engram(blocks: lowBits(20), 0, 0, 0)
        let drawers = [makeDrawer(id: "first"),
                       makeDrawer(id: "second"),
                       makeDrawer(id: "third")]
        let out = mmrRank(
            candidates: drawers,
            query: query,
            lambda: 0.5,
            k: 3,
            fingerprint: { _ in same }
        )
        #expect(out.map(\.id) == ["first", "second", "third"])
    }
}

// MARK: - Test helper

/// Minimal `Drawer` whose `id` encodes which hand-built fingerprint
/// the test closure should return. Field values other than `id` are
/// irrelevant to MMR math (the function never reads Drawer content;
/// similarity comes entirely from the supplied fingerprints).
private func makeDrawer(id: String) -> Drawer {
    Drawer(
        id: id,
        content: "",
        parentNodeId: "test-room-node",
        sourceFile: nil,
        chunkIndex: nil,
        addedBy: "test",
        filedAt: Date(timeIntervalSince1970: 0),
        embeddingModelID: "test-embed-v1",
        tombstonedAt: nil,
        removedByBatch: nil,
        provenance: 0,
        adjectiveBitmap: 0,
        operationalBitmap: 0,
        lineageID: UUID(),
        udcCode: "",
        udcFacets: nil,
        wikidataQID: nil,
        wikidataQidsSecondary: nil
    )
}
