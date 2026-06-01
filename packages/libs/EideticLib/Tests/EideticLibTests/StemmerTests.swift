// StemmerTests.swift
//
// Conformance gate for the Swift Porter2 implementation
// against the canonical Snowball English corpus shipped at
// Resources/SnowballEnglish.json. Every word in the corpus
// must produce the byte-identical stem in Swift that the
// Rust port produces via the rust-stemmers crate.

import Testing
import Foundation
@testable import EideticLib
@testable import LatticeLib

@Suite("Stemmer Snowball conformance")
struct StemmerTests {

    struct StemPair: Codable {
        let input: String
        let expectedStem: String

        enum CodingKeys: String, CodingKey {
            case input
            case expectedStem = "expected_stem"
        }
    }

    struct CorpusFile: Codable {
        let schemaVersion: String
        let pairs: [StemPair]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case pairs
        }
    }

    func loadCorpus() throws -> CorpusFile {
        let data = try #require(
            Stemmer.bundledReferenceCorpus(),
            "SnowballEnglish.json missing from module bundle"
        )
        return try JSONDecoder().decode(CorpusFile.self, from: data)
    }

    @Test("corpus loads")
    func corpusLoads() throws {
        let corpus = try loadCorpus()
        #expect(corpus.schemaVersion == "1")
        #expect(!corpus.pairs.isEmpty)
    }

    @Test("stemmer matches canonical corpus")
    func stemmerMatchesCanonicalCorpus() throws {
        let corpus = try loadCorpus()
        var failures: [String] = []
        for pair in corpus.pairs {
            let actual = Stemmer.stem(pair.input)
            if actual != pair.expectedStem {
                failures.append(
                    "\(pair.input): expected \(pair.expectedStem) got \(actual)"
                )
            }
        }
        #expect(
            failures.isEmpty,
            "Snowball conformance failures (\(failures.count) of \(corpus.pairs.count)):\n\(failures.joined(separator: "\n"))"
        )
    }

    @Test("determinism")
    func determinism() {
        let a = Stemmer.stem("running")
        let b = Stemmer.stem("running")
        #expect(a == b)
    }

    @Test("empty string yields empty")
    func emptyStringYieldsEmpty() {
        #expect(Stemmer.stem("") == "")
    }

    // Explicit spot checks mirroring the Rust stemmer.rs #[test] set
    // (rust-stemmers Porter2). These are subsumed by the full-corpus
    // conformance gate above but are asserted directly so the Swift/Rust
    // parity set is mirrored one-to-one.

    @Test("running stems to run")
    func runningStemsToRun() {
        #expect(Stemmer.stem("running") == "run")
    }

    @Test("ran stems to ran")
    func ranStemsToRan() {
        // Porter2 does not catch irregular past tense; "ran" stays "ran".
        #expect(Stemmer.stem("ran") == "ran")
    }

    @Test("computer and computing collapse to same stem")
    func computerAndComputingCollapseToSameStem() {
        #expect(Stemmer.stem("computer") == Stemmer.stem("computing"))
    }

    @Test("chemistry stems consistently")
    func chemistryStemsConsistently() {
        #expect(!Stemmer.stem("chemistry").isEmpty)
        #expect(!Stemmer.stem("chemical").isEmpty)
    }
}
