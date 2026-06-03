// WordClassTests.swift
//
// Per-type coverage for the WordClass enum
// (Sources/EideticLib/WordClass.swift): the String-backed FDC encoder
// Step 1 label. The stable lowercase JSON form ("noun"/"verb"/"other")
// is the cross-leg contract the shared conformance vectors and the
// Rust port read; mirrors the Rust word_class.rs serialization test.

import Testing
import Foundation
@testable import EideticLib
@testable import LatticeLib

@Suite("WordClass enum")
struct WordClassTests {

    @Test("raw values are stable lowercase strings")
    func rawValuesAreStableLowercase() {
        #expect(WordClass.noun.rawValue == "noun")
        #expect(WordClass.verb.rawValue == "verb")
        #expect(WordClass.other.rawValue == "other")
    }

    @Test("serializes to lowercase JSON")
    func serializesToLowercaseJSON() throws {
        // Mirrors the Rust port's `word_class_serializes_lowercase`.
        let data = try JSONEncoder().encode(WordClass.noun)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json == "\"noun\"")
    }

    @Test("decodes from lowercase JSON")
    func decodesFromLowercaseJSON() throws {
        let decoded = try JSONDecoder().decode(
            WordClass.self,
            from: Data("\"verb\"".utf8)
        )
        #expect(decoded == .verb)
    }

    @Test("Codable round-trips every case")
    func codableRoundTripsEveryCase() throws {
        for value in [WordClass.noun, .verb, .other] {
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(WordClass.self, from: data)
            #expect(decoded == value)
        }
    }

    @Test("cases are distinct")
    func casesAreDistinct() {
        #expect(WordClass.noun != .verb)
        #expect(WordClass.verb != .other)
        #expect(WordClass.noun != .other)
    }
}
