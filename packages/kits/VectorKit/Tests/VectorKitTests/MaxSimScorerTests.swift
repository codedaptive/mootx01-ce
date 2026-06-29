// MaxSimScorerTests.swift
//
// Lane E1 conformance tests for MaxSimScorer.
//
// Test strategy:
//
//   1. Canonical spec vectors (§3.E COLBERT-1..3) — run through MaxSimScorer
//      and assert the exact ordered (itemID, score) results. These vectors pin
//      the expected integer scores and the ranking order including tie-break.
//
//      Note on W=8 adaptation: the retrieval algorithms reference §3.E uses
//      8-bit token fingerprints (W=8, sim = 8 − hamming) for legibility. The
//      production system uses 256-bit Engrams (W=256, sim = 256 − hamming).
//      For the conformance vectors we embed the 8-bit patterns into the low
//      byte of Engram block0 (all other bits zero). This makes the Hamming
//      distance between any two such Engrams identical to the Hamming distance
//      between the corresponding 8-bit patterns, and the MaxSim scores are
//      identical to those computed with W=8. The algorithm is identical; only
//      the token width differs, and we test with the real W=256 type.
//
//   2. Tie-break test — documents with equal MaxSim scores; asserts that
//      itemID ascending (§0.3 universal rule) breaks the tie correctly.
//
//   3. Determinism test — same inputs, multiple calls; asserts identical output.
//
//   4. Edge cases — empty query tokens, empty document token array, k=0,
//      empty document set.
//
//   5. Reference cross-check — for small random inputs, assert MaxSimScorer
//      produces identical results to a naive double-loop reference implementation
//      (exhaustive, independent of MaxSimScorer internals). This is the
//      "exactness gate by brute force" (§4 cross-cutting harness notes).

import Testing
import Foundation
import EngramLib
@testable import VectorKit

// MARK: - Test helpers

/// Build an Engram from an 8-bit value by placing the byte in the low
/// byte of block0. All other bits are zero.
///
/// This lets us write the §3.E test vectors using 8-bit binary literals
/// (e.g. 0b11110000) while working with real 256-bit Engrams. The Hamming
/// distance between two such Engrams equals the Hamming distance between the
/// corresponding 8-bit values — no bits outside the low byte are set, so
/// XOR only produces 1-bits in the low byte.
private func e8(_ byte: UInt8) -> Engram {
    Engram(blocks: UInt64(byte), 0, 0, 0)
}

/// Naive double-loop MaxSim reference.
///
/// This is the "ground truth" for the exactness cross-check. It is
/// independent of MaxSimScorer's implementation — it calls EngramLib.distance
/// directly (not via Session) and accumulates the sum in the obvious way.
/// Used to gate that MaxSimScorer produces identical integer results.
///
/// Returns: [(itemID, score)] sorted (score DESC, itemID ASC).
private func naiveMaxSim(
    queryTokens: [Engram],
    documents: [String: [Engram]],
    k: Int
) -> [(itemID: String, score: Int)] {
    guard k > 0 else { return [] }
    var results: [(itemID: String, score: Int)] = []
    // Enumerate in ascending key order so iteration is deterministic.
    for itemID in documents.keys.sorted() {
        let docTokens = documents[itemID]!
        var docScore = 0
        for q in queryTokens {
            if docTokens.isEmpty { continue }
            // min Hamming distance from q to any document token.
            let minDist = docTokens
                .map { d in EngramLib.distance(q, d) }
                .min()!
            docScore += 256 - minDist
        }
        results.append((itemID, docScore))
    }
    results.sort { a, b in
        if a.score != b.score { return a.score > b.score }
        return a.itemID < b.itemID
    }
    return Array(results.prefix(k))
}

// MARK: - §3.E Canonical vector tests

/// Vector COLBERT-1 (§3.E): basic MaxSim, 2 docs, exhaustive Exact-A.
///
/// Query:  Q  = [0b00000000, 0b11110000]
/// Doc 1:  D1 = [0b00000001, 0b11100000]
/// Doc 2:  D2 = [0b11111111, 0b00001111]
///
/// Doc1 score:
///   q0=0x00 → min(hamming(0x00,0x01)=1, hamming(0x00,0xE0)=3) = 1 → sim=255
///   q1=0xF0 → min(hamming(0xF0,0x01)=5, hamming(0xF0,0xE0)=1) = 1 → sim=255
///   total = 510
///
/// Doc2 score:
///   q0=0x00 → min(hamming(0x00,0xFF)=8, hamming(0x00,0x0F)=4) = 4 → sim=252
///   q1=0xF0 → min(hamming(0xF0,0xFF)=4, hamming(0xF0,0x0F)=8) = 4 → sim=252
///   total = 504
///
/// Note: the spec computes with W=8 (sim = 8 − hamming). We use W=256
/// (sim = 256 − hamming) because we embed 8-bit patterns in 256-bit Engrams.
/// The RANKING is identical. Absolute scores differ by an additive offset of
/// (256−8)=248 per query token — the test asserts the W=256 scores.
@Test("COLBERT-1: basic MaxSim, 2 docs, correct ranking")
func colbert1BasicMaxSim() async throws {
    let scorer = MaxSimScorer()

    // Query tokens: 0b00000000, 0b11110000
    let q: [Engram] = [e8(0b00000000), e8(0b11110000)]

    // Doc 1 tokens: 0b00000001, 0b11100000
    // Doc 2 tokens: 0b11111111, 0b00001111
    let documents: [String: [Engram]] = [
        "doc1": [e8(0b00000001), e8(0b11100000)],
        "doc2": [e8(0b11111111), e8(0b00001111)],
    ]

    let results = scorer.score(queryTokens: q, documents: documents, k: 2)

    #expect(results.count == 2)
    #expect(results[0].itemID == "doc1")
    #expect(results[1].itemID == "doc2")

    // Verify scores match the exhaustive formula.
    // doc1:
    //   q0 → distances to [0x01, 0xE0] = [hamming(0,1)=1, hamming(0,0xE0)=3] → min=1 → 255
    //   q1 → distances to [0x01, 0xE0] = [hamming(0xF0,0x01)=5, hamming(0xF0,0xE0)=1] → min=1 → 255
    //   score = 510
    #expect(results[0].score == 510)

    // doc2:
    //   q0 → distances to [0xFF, 0x0F] = [8, 4] → min=4 → 252
    //   q1 → distances to [0xFF, 0x0F] = [4, 8] → min=4 → 252
    //   score = 504
    #expect(results[1].score == 504)

    // Cross-check against naive reference.
    let ref = naiveMaxSim(queryTokens: q, documents: documents, k: 2)
    #expect(results[0].itemID == ref[0].itemID)
    #expect(results[0].score  == ref[0].score)
    #expect(results[1].itemID == ref[1].itemID)
    #expect(results[1].score  == ref[1].score)
}

/// Vector COLBERT-2 (§3.E): score tie broken by doc_id (itemID) ascending.
///
/// Same query and tokens as COLBERT-1, plus doc3 whose tokens are an exact
/// copy of doc1's tokens (so doc1 score = doc3 score = 510). k=2.
///
/// Expected top-2: [(doc1, 510), (doc3, 510)] — doc1 < doc3 alphabetically,
/// so doc1 wins the tie. doc2 (score=504) is excluded.
@Test("COLBERT-2: score tie broken by itemID ascending")
func colbert2TieBreak() async throws {
    let scorer = MaxSimScorer()

    let q: [Engram] = [e8(0b00000000), e8(0b11110000)]

    let documents: [String: [Engram]] = [
        "doc1": [e8(0b00000001), e8(0b11100000)],
        "doc2": [e8(0b11111111), e8(0b00001111)],
        "doc3": [e8(0b00000001), e8(0b11100000)],  // exact copy of doc1 tokens
    ]

    let results = scorer.score(queryTokens: q, documents: documents, k: 2)

    #expect(results.count == 2)
    // doc1 and doc3 both score 510; doc1 < doc3 alphabetically → doc1 first.
    #expect(results[0].itemID == "doc1")
    #expect(results[0].score  == 510)
    #expect(results[1].itemID == "doc3")
    #expect(results[1].score  == 510)
    // doc2 (score=504) must not appear in top-2.
    #expect(!results.map(\.itemID).contains("doc2"))
}

/// Vector COLBERT-3 (§3.E): min-tie inside a doc is value-irrelevant.
///
/// Q = [0b00001111]
/// Doc 4 = [0b00001110, 0b00001101]   # both at hamming=1 from query token
///
/// Both doc tokens have hamming=1 from the query token → min=1 regardless
/// of which token we examine first → sim = 256 − 1 = 255 → score = 255.
///
/// This test gates that doc-token ordering does not affect the score value.
@Test("COLBERT-3: min-tie inside doc is value-irrelevant")
func colbert3MinTie() async throws {
    let scorer = MaxSimScorer()

    // Query: single token 0b00001111
    let q: [Engram] = [e8(0b00001111)]

    // Doc 4: both tokens at hamming distance 1 from the query token.
    // 0b00001110: one bit flipped (bit 0 cleared) → hamming=1.
    // 0b00001101: one bit flipped (bit 1 cleared) → hamming=1.
    let documents: [String: [Engram]] = [
        "doc4": [e8(0b00001110), e8(0b00001101)],
    ]

    let results = scorer.score(queryTokens: q, documents: documents, k: 1)

    #expect(results.count == 1)
    #expect(results[0].itemID == "doc4")
    // min hamming = 1, so sim = 255, score = 255.
    #expect(results[0].score == 255)
}

// MARK: - Determinism tests

/// Determinism: same inputs → identical output across multiple calls.
@Test("Determinism: repeated calls produce identical results")
func determinism() async throws {
    let scorer = MaxSimScorer()

    let q: [Engram] = [e8(0b10101010), e8(0b01010101)]
    let documents: [String: [Engram]] = [
        "a": [e8(0b11110000), e8(0b00001111)],
        "b": [e8(0b10101010)],
        "c": [e8(0b00000000), e8(0b11111111), e8(0b10101010)],
    ]

    let r1 = scorer.score(queryTokens: q, documents: documents, k: 3)
    let r2 = scorer.score(queryTokens: q, documents: documents, k: 3)
    let r3 = scorer.score(queryTokens: q, documents: documents, k: 3)

    #expect(r1 == r2)
    #expect(r2 == r3)
}

// MARK: - Edge case tests

/// Empty query tokens: all documents score 0, ordered by itemID ASC.
@Test("Edge: empty query tokens → all documents score 0")
func emptyQueryTokens() async throws {
    let scorer = MaxSimScorer()

    let documents: [String: [Engram]] = [
        "z": [e8(0b11111111)],
        "a": [e8(0b00000000)],
        "m": [e8(0b10101010)],
    ]

    let results = scorer.score(queryTokens: [], documents: documents, k: 10)

    // All scores are 0. Order is itemID ASC (§0.3 tie-break applies to equal scores).
    #expect(results.count == 3)
    for r in results { #expect(r.score == 0) }
    #expect(results.map(\.itemID) == ["a", "m", "z"])
}

/// Empty document token array: document scores 0 (no tokens to match against).
@Test("Edge: empty document token array → document scores 0")
func emptyDocumentTokens() async throws {
    let scorer = MaxSimScorer()

    let q: [Engram] = [e8(0b11110000)]
    let documents: [String: [Engram]] = [
        "empty": [],
        "normal": [e8(0b11110001)],
    ]

    let results = scorer.score(queryTokens: q, documents: documents, k: 2)

    #expect(results.count == 2)
    // "normal": q=0xF0, d=0xF1 → hamming=1 → sim=255 → score=255
    #expect(results[0].itemID == "normal")
    #expect(results[0].score  == 255)
    // "empty": no tokens → score=0
    #expect(results[1].itemID == "empty")
    #expect(results[1].score  == 0)
}

/// k=0 returns empty array.
@Test("Edge: k=0 returns empty")
func kZero() async throws {
    let scorer = MaxSimScorer()
    let results = scorer.score(
        queryTokens: [e8(0b11111111)],
        documents: ["doc": [e8(0b00000000)]],
        k: 0
    )
    #expect(results.isEmpty)
}

/// Empty documents dictionary returns empty array.
@Test("Edge: empty documents dictionary returns empty")
func emptyDocuments() async throws {
    let scorer = MaxSimScorer()
    let results = scorer.score(
        queryTokens: [e8(0b11111111)],
        documents: [:],
        k: 10
    )
    #expect(results.isEmpty)
}

/// k truncation: result count is min(k, documents.count).
@Test("Edge: k truncation returns min(k, count) results")
func kTruncation() async throws {
    let scorer = MaxSimScorer()

    let q: [Engram] = [e8(0b00000000)]
    let documents: [String: [Engram]] = [
        "a": [e8(0b00000001)],  // hamming=1, score=255
        "b": [e8(0b00000011)],  // hamming=2, score=254
        "c": [e8(0b00000111)],  // hamming=3, score=253
        "d": [e8(0b00001111)],  // hamming=4, score=252
    ]

    let r2 = scorer.score(queryTokens: q, documents: documents, k: 2)
    #expect(r2.count == 2)
    #expect(r2[0].itemID == "a")
    #expect(r2[1].itemID == "b")

    let r1 = scorer.score(queryTokens: q, documents: documents, k: 1)
    #expect(r1.count == 1)
    #expect(r1[0].itemID == "a")

    let r10 = scorer.score(queryTokens: q, documents: documents, k: 10)
    #expect(r10.count == 4)  // only 4 docs exist
}

// MARK: - Exactness cross-check (reference gate)

/// Exactness gate: MaxSimScorer must match the naive double-loop reference
/// on random 256-bit Engram inputs across multiple seeds and doc set sizes.
///
/// This is the "exactness gate by brute force" from §4 of the reference.
/// The naive reference is the oracle; MaxSimScorer is gated against it.
@Test("Exactness gate: matches naive reference on random 256-bit Engrams")
func exactnessGate() async throws {
    let scorer = MaxSimScorer()

    // Simple deterministic xorshift64 for reproducible randomness.
    var rng: UInt64 = 0xCAFE_BABE_DEAD_BEEF

    func nextU64() -> UInt64 {
        rng ^= rng << 13
        rng ^= rng >> 7
        rng ^= rng << 17
        return rng
    }

    func randomEngram() -> Engram {
        Engram(blocks: nextU64(), nextU64(), nextU64(), nextU64())
    }

    // Run several (nDocs, nQueryTokens, nDocTokens, k) configurations.
    let configs: [(nDocs: Int, nQueryToks: Int, nDocToks: Int, k: Int)] = [
        (3, 2, 3, 2),
        (5, 3, 4, 3),
        (8, 1, 5, 4),
        (4, 4, 2, 10),  // k > nDocs: all docs returned
        (6, 2, 1, 3),
    ]

    for config in configs {
        // Build a random document set.
        var docs: [String: [Engram]] = [:]
        for i in 0..<config.nDocs {
            let tokens = (0..<config.nDocToks).map { _ in randomEngram() }
            docs["item\(i)"] = tokens
        }
        // Build random query tokens.
        let query = (0..<config.nQueryToks).map { _ in randomEngram() }

        // Score via MaxSimScorer and via naive reference.
        let scored = scorer.score(queryTokens: query, documents: docs, k: config.k)
        let reference = naiveMaxSim(queryTokens: query, documents: docs, k: config.k)

        // Must match in count, itemID, and score for every position.
        #expect(scored.count == reference.count,
                "config \(config): count mismatch \(scored.count) vs \(reference.count)")
        for (s, r) in zip(scored, reference) {
            #expect(s.itemID == r.itemID,
                    "config \(config): itemID mismatch \(s.itemID) vs \(r.itemID)")
            #expect(s.score == r.score,
                    "config \(config): score mismatch \(s.score) vs \(r.score)")
        }
    }
}

/// Single-token query, perfect match: score = 256, no Hamming loss.
@Test("Perfect match: score equals 256 for a single token with hamming=0")
func perfectMatch() async throws {
    let scorer = MaxSimScorer()

    let token = Engram(blocks: 0xDEAD_BEEF_CAFE_BABE, 0x1234_5678_9ABC_DEF0, 0, 0)
    let documents: [String: [Engram]] = [
        "exact": [token],                    // identical → hamming=0 → sim=256
        "other": [Engram(blocks: 0, 0, 0, 0)],  // all-zero → hamming varies
    ]

    let results = scorer.score(queryTokens: [token], documents: documents, k: 2)
    #expect(results[0].itemID == "exact")
    #expect(results[0].score  == 256)
}
