// StemmerTests.swift
//
// Conformance gate for the Swift Porter2 implementation
// against the canonical Snowball English corpus shipped at
// Resources/SnowballEnglish.json. Every word in the corpus
// must produce the byte-identical stem in Swift that the
// Rust port produces via the rust-stemmers crate.

import XCTest
@testable import EideticLib

final class StemmerTests: XCTestCase {

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
        let data = try XCTUnwrap(
            Stemmer.bundledReferenceCorpus(),
            "SnowballEnglish.json missing from module bundle"
        )
        return try JSONDecoder().decode(CorpusFile.self, from: data)
    }

    func testCorpusLoads() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.schemaVersion, "1")
        XCTAssertFalse(corpus.pairs.isEmpty)
    }

    func testStemmerMatchesCanonicalCorpus() throws {
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
        XCTAssertTrue(
            failures.isEmpty,
            "Snowball conformance failures (\(failures.count) of \(corpus.pairs.count)):\n"
            + failures.joined(separator: "\n")
        )
    }

    func testDeterminism() {
        let a = Stemmer.stem("running")
        let b = Stemmer.stem("running")
        XCTAssertEqual(a, b)
    }

    func testEmptyStringYieldsEmpty() {
        XCTAssertEqual(Stemmer.stem(""), "")
    }
}
