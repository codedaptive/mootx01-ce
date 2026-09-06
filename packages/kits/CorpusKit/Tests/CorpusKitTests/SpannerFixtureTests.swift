// SpannerFixtureTests.swift
//
// Pins `Spanner.spans` to the shared cross-port fixture
// `SynapseKit/Tests/Fixtures/encoder/spanner_vectors.json` (the Rust leg
// reads the SAME file in rust/tests/spanner_fixture_tests.rs).
//
// Failure modes this catches: an off-by-one at the tail (the reference
// stops at `start <= wordCount - windowWords`, and the widened rule pins the
// final start), a longest-first reordering, or a cap that lets more than
// `maxSpans` spans through.

import Testing
import Foundation
@testable import CorpusKit

private struct SpannerFixture: Decodable {
    struct Case: Decodable {
        let word_count: Int
        let window_words: Int
        let overlap_divisor: Int
        let max_spans: Int
        let spans: [[Int]]
    }
    let cases: [Case]
}

/// `#filePath` → …/CorpusKit/Tests/CorpusKitTests/<this file>; the fixture
/// lives four levels up under SynapseKit.
private func spannerFixtureURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CorpusKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // CorpusKit
        .deletingLastPathComponent()   // kits
        .appendingPathComponent("SynapseKit/Tests/Fixtures/encoder/spanner_vectors.json")
}

@Suite("Spanner — shared fixture")
struct SpannerFixtureTests {

    @Test("every fixture case reproduces its span bounds exactly")
    func fixtureCases() throws {
        let data = try Data(contentsOf: spannerFixtureURL())
        let fixture = try JSONDecoder().decode(SpannerFixture.self, from: data)
        // 10 word counts × 2 windows. A shorter file means the fixture was
        // truncated; a longer one means a case was added without a twin.
        #expect(fixture.cases.count == 20)
        for c in fixture.cases {
            let got = Spanner.spans(
                wordCount: c.word_count, windowWords: c.window_words,
                overlapDivisor: c.overlap_divisor, maxSpans: c.max_spans
            ).map { [$0.start, $0.end] }
            #expect(got == c.spans, "wordCount=\(c.word_count) window=\(c.window_words)")
        }
    }

    @Test("cap widening stays at or under maxSpans, ends at wordCount, ascending")
    func wideningInvariants() {
        for wordCount in stride(from: 200, through: 6000, by: 173) {
            let spans = Spanner.spans(wordCount: wordCount, windowWords: 60, overlapDivisor: 2, maxSpans: 32)
            #expect(spans.count <= 32, "wordCount=\(wordCount)")
            #expect(spans.count > 1)
            // The widened rule pins the tail; the plain rule leaves the
            // reference remainder. Either way the count never exceeds the cap
            // and the starts ascend strictly.
            if wordCount - 60 > 31 * 30 {
                #expect(spans.last?.end == wordCount, "wordCount=\(wordCount)")
            }
            for (a, b) in zip(spans, spans.dropFirst()) {
                #expect(a.start < b.start)
                #expect(a.end - a.start == 60)
            }
        }
    }

    @Test("words is the product keyword split")
    func wordsMatchesKeywordTokens() {
        let text = "Hello, World! Painting in Brazil since 1999 — ok."
        #expect(Spanner.words(text) == defaultKeywordTokens(text))
        #expect(Spanner.words(text) == ["hello", "world", "painting", "in", "brazil", "since", "1999", "ok"])
    }
}
