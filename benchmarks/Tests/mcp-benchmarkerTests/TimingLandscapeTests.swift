// TimingLandscapeTests.swift — the Swift half of the landscape cross-port gate.
//
// The three frozen ids below are the same literals the Rust twin pins in
// `rust/src/timing_landscape.rs`. If either port's id derivation changes, the
// two landscapes stop being the same landscape and one of these two test files
// goes red. A shape-only test would not catch that: both ports would still
// produce well-formed UUIDs, just different ones, and a published recipe would
// no longer reproduce.

import Testing
import Foundation
@testable import mcp_benchmarker

@Suite("Timing landscape")
struct TimingLandscapeTests {

    private var rows: [TimingLandscapeRow] {
        [
            TimingLandscapeRow(content: "user: alpha", sourceKey: "q1/0/0"),
            TimingLandscapeRow(content: "assistant: beta", sourceKey: "q1/0/1"),
            TimingLandscapeRow(content: "user: gamma", sourceKey: "q2/0/0"),
        ]
    }

    /// The id is a pure function of the source key, so a corpus turn keeps its
    /// identity across runs and across ports.
    @Test("row id is derived from the source key")
    func rowIDIsDerivedFromSourceKey() {
        #expect(landscapeRowID(sourceKey: "q1/0/0") == landscapeRowID(sourceKey: "q1/0/0"))
        #expect(landscapeRowID(sourceKey: "q1/0/0") != landscapeRowID(sourceKey: "q1/0/1"))

        // UUIDv4 shape: version nibble 4, variant bits 10xx.
        let id = landscapeRowID(sourceKey: "q1/0/0")
        #expect(id.count == 36)
        let version = id[id.index(id.startIndex, offsetBy: 14)]
        #expect(version == "4")
        let variant = id[id.index(id.startIndex, offsetBy: 19)]
        #expect("89ab".contains(variant), "variant nibble was \(variant)")
    }

    /// A prefix of a longer landscape is the shorter landscape. This is what
    /// makes a scaling curve one curve rather than three samples.
    @Test("a prefix of a larger landscape is the smaller one")
    func prefixIsTheSmallerLandscape() {
        let all = corpusLandscapeRecords(rows: rows, from: 0, to: 3)
        let head = corpusLandscapeRecords(rows: rows, from: 0, to: 2)
        #expect(all.prefix(2).map(\.id) == head.map(\.id))
        #expect(all.prefix(2).map(\.content) == head.map(\.content))
    }

    /// Past the end of the corpus the rows cycle, and a reused row is a
    /// distinct database row with a distinct id.
    @Test("cycling past the corpus keeps ids unique")
    func cyclingKeepsIDsUnique() {
        let recs = corpusLandscapeRecords(rows: rows, from: 0, to: 7)
        #expect(recs.count == 7)
        #expect(recs[0].content == recs[3].content)
        #expect(recs[0].id != recs[3].id)
        #expect(Set(recs.map(\.id)).count == 7, "every landscape row needs its own id")
    }

    /// Event times are the lane's own monotonic sequence, not the corpus's, so
    /// the recency distribution is a function of row count rather than corpus.
    @Test("event times are monotonic and independent of the corpus")
    func eventTimesAreMonotonic() {
        let recs = corpusLandscapeRecords(rows: rows, from: 0, to: 3)
        #expect(recs[0].eventTime < recs[1].eventTime)
        #expect(recs[1].eventTime < recs[2].eventTime)
    }

    @Test("recipe records the licence with the corpus")
    func recipeCarriesLicence() {
        let r = TimingLandscapeRecipe.corpus(.longmemeval, variant: "s", rows: 2000, seed: 7)
        #expect(r.corpus == "longmemeval")
        #expect(r.corpusLicence == "CC BY 4.0")
        #expect(r.rows == 2000)

        let s = TimingLandscapeRecipe.synthetic(rows: 2000, seed: 7)
        #expect(s.corpus == nil)
        #expect(s.corpusLicence == nil)
    }

    /// The cross-port gate. These literals are pinned identically in
    /// `rust/src/timing_landscape.rs`.
    @Test("frozen ids match the Rust twin")
    func frozenIDsMatchRustTwin() {
        #expect(landscapeRowID(sourceKey: "q1/0/0") == "1887b499-a633-450f-8ef3-562fc5f11ac5")
        #expect(landscapeRowID(sourceKey: "q1/0/1") == "1887b399-a633-435c-986b-47647abffac7")
        #expect(landscapeRowID(sourceKey: "q2/0/0#1") == "7223e9b5-89f8-4356-a702-c5252eac9e35")
    }

    /// The frozen names below are the same literals the Rust twin pins in
    /// `rust/src/timing_landscape.rs`. A landscape stored by one port must be
    /// found by the other, or a published recipe stops reproducing across
    /// implementations.
    @Test("cache key matches the Rust twin")
    func cacheKeyMatchesRustTwin() {
        #expect(timingLandscapeCacheKey(
            source: .corpus, corpus: .longmemeval, variant: "s",
            seed: 20_260_813, size: 100_000) == "longmemeval-s-seed20260813-rows100000")
        #expect(timingLandscapeCacheKey(
            source: .synthetic, corpus: .longmemeval, variant: "s",
            seed: 7, size: 2_000) == "synthetic-seed7-rows2000")
    }

    /// A synthetic key never carries the corpus or variant: those do not shape
    /// its rows, and including them would split one landscape across several
    /// directories.
    @Test("a synthetic key ignores corpus and variant")
    func syntheticKeyIgnoresCorpusAndVariant() {
        #expect(timingLandscapeCacheKey(
            source: .synthetic, corpus: .longmemeval, variant: "s", seed: 1, size: 10)
            == timingLandscapeCacheKey(
                source: .synthetic, corpus: .lmeb, variant: "m", seed: 1, size: 10))
    }

    /// Every field that changes the rows changes the key, so one entry is never
    /// read under a recipe that did not produce it.
    @Test("every recipe field changes the key")
    func everyRecipeFieldChangesTheKey() {
        let base = timingLandscapeCacheKey(
            source: .corpus, corpus: .longmemeval, variant: "s", seed: 1, size: 10)
        let others = [
            timingLandscapeCacheKey(
                source: .synthetic, corpus: .longmemeval, variant: "s", seed: 1, size: 10),
            timingLandscapeCacheKey(
                source: .corpus, corpus: .longmemeval, variant: "m", seed: 1, size: 10),
            timingLandscapeCacheKey(
                source: .corpus, corpus: .longmemeval, variant: "s", seed: 2, size: 10),
            timingLandscapeCacheKey(
                source: .corpus, corpus: .longmemeval, variant: "s", seed: 1, size: 20),
        ]
        for other in others { #expect(base != other) }
    }

    /// The recipe's wire shape is snake_case, matching every other field in the
    /// timing report.
    @Test("recipe encodes as snake_case")
    func recipeWireShape() throws {
        let r = TimingLandscapeRecipe.corpus(.longmemeval, variant: "s", rows: 10, seed: 1)
        let data = try JSONEncoder().encode(r)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("corpus_variant"))
        #expect(json.contains("corpus_licence"))
        #expect(!json.contains("corpusVariant"))
    }
}
