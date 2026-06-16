// ShingleSimilarityTests.swift
//
// swift-testing peer suite for Sources/SubstrateML/ShingleSimilarity.swift.
// The Rust twin (rust/src/shingle_similarity.rs) carries the same set of
// inline #[test] cases; both ports assert the closed-form properties the
// character-shingle Jaccard must satisfy, plus the edge-case contract the
// recall-path delegators depend on (short strings, empty strings, both-
// empty). Cross-port bit-identity is enforced by the conformance harness
// (vectors/shingle_similarity.json); this suite pins the behaviour.

import Testing
@testable import SubstrateML

@Suite("ShingleSimilarity")
struct ShingleSimilarityTests {

    // MARK: - shingles()

    @Test("empty input has no shingles")
    func emptyHasNoShingles() {
        #expect(ShingleSimilarity.shingles("").isEmpty)
    }

    @Test("short input returns the whole lowercased string as one shingle")
    func shortInputWholeString() {
        #expect(ShingleSimilarity.shingles("ab") == ["ab"])
        #expect(ShingleSimilarity.shingles("AB") == ["ab"])
        #expect(ShingleSimilarity.shingles("x") == ["x"])
    }

    @Test("windows are three-character lowercased")
    func windowsThreeChar() {
        #expect(ShingleSimilarity.shingles("catdog") == ["cat", "atd", "tdo", "dog"])
        #expect(ShingleSimilarity.shingles("CatDog") == ["cat", "atd", "tdo", "dog"])
    }

    // MARK: - similarity()

    @Test("identical strings score exactly 1.0")
    func identicalScoresOne() {
        #expect(ShingleSimilarity.similarity("organic chemistry", "organic chemistry") == 1.0)
    }

    @Test("disjoint strings score exactly 0.0")
    func disjointScoresZero() {
        #expect(ShingleSimilarity.similarity("abcdef", "ghijkl") == 0.0)
    }

    @Test("both-empty inputs score 0.0")
    func bothEmptyScoresZero() {
        #expect(ShingleSimilarity.similarity("", "") == 0.0)
    }

    @Test("one-empty input scores 0.0 (no intersection)")
    func oneEmptyScoresZero() {
        #expect(ShingleSimilarity.similarity("", "catdog") == 0.0)
        #expect(ShingleSimilarity.similarity("catdog", "") == 0.0)
    }

    @Test("partial overlap is the intersection/union ratio")
    func partialOverlapIsRatio() {
        // "abcd" -> {abc, bcd}; "abce" -> {abc, bce}.
        // intersection {abc} = 1; union {abc, bcd, bce} = 3.
        #expect(ShingleSimilarity.similarity("abcd", "abce") == Float32(1) / Float32(3))
    }

    @Test("similarity is symmetric")
    func symmetric() {
        let ab = ShingleSimilarity.similarity("organic chemistry", "organic physics")
        let ba = ShingleSimilarity.similarity("organic physics", "organic chemistry")
        #expect(ab == ba)
    }

    @Test("result is always in [0, 1]")
    func inUnitRange() {
        let pairs = [("hello world", "hello there"),
                     ("abc", "xyz"),
                     ("aaa", "aaaa"),
                     ("the quick brown fox", "the quick brown dog")]
        for (a, b) in pairs {
            let s = ShingleSimilarity.similarity(a, b)
            #expect(s >= 0 && s <= 1)
        }
    }
}
