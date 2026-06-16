// LatticeLanguageConformanceTests.swift
//
// Swift half of the Swift↔Rust agreement gate for the deterministic
// language layer: the compatibility-fold normalizer and the HMM/Viterbi
// novel-token tagger. Reads the SAME shared fixtures the Rust leg reads
// (rust/tests/lattice_conformance_test.rs), via a compile-time #filePath
// anchor — the established convention from FDCConformanceTests.swift.
//
//   * normalize_conformance.json — Normalizer.normalize == Rust normalize
//   * tag_conformance.json       — HMMTagger.tag == Rust hmm_tag
//
// `HMMTagger` and `Normalizer` are compiled on every platform (no #if
// guard), so this Swift leg exercises the very code the non-Apple runtime
// dispatches to — even when these tests run on macOS. The HMM is NOT
// expected to match Apple's NLTagger; its guarantee is cross-platform
// self-consistency of the non-Apple path. See HMMTagger.swift.
//
// Seed: N/A (determinism comes from the checked-in tables and integer
// scoring, not from a hash-family seed).

import Testing
import Foundation
@testable import LatticeLib

// MARK: - Shared-fixture loader

private enum LanguageFixtures {
    /// Resolves a fixture under rust/tests/fixtures/ relative to this source
    /// file, matching FDCConformanceTests's #filePath-anchor convention.
    static func url(_ name: String, sourceFile: String = #filePath) -> URL {
        let thisFile = URL(fileURLWithPath: sourceFile)
        let packageRoot = thisFile
            .deletingLastPathComponent()  // LatticeLibTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // package root (LatticeLib/)
        return packageRoot
            .appendingPathComponent("rust")
            .appendingPathComponent("tests")
            .appendingPathComponent("fixtures")
            .appendingPathComponent(name)
    }
}

// MARK: - Normalize conformance

private struct NormalizeVector: Decodable {
    let input: String
    let expected: String
}

@Suite("Normalize Swift/Rust conformance vectors")
struct NormalizeConformanceTests {

    private func loadVectors() throws -> [NormalizeVector] {
        let fixtureURL = LanguageFixtures.url("normalize_conformance.json")
        let data = try #require(
            try? Data(contentsOf: fixtureURL),
            "normalize_conformance.json must be readable at \(fixtureURL.path)"
        )
        return try JSONDecoder().decode([NormalizeVector].self, from: data)
    }

    @Test("all normalize vectors match")
    func allNormalizeVectorsMatch() throws {
        let vectors = try loadVectors()
        #expect(!vectors.isEmpty, "fixture must contain at least one vector")

        var failures: [String] = []
        for v in vectors {
            let got = Normalizer.normalize(v.input)
            if got != v.expected {
                failures.append(
                    "MISMATCH input=\(v.input.debugDescription) expected=\(v.expected.debugDescription) got=\(got.debugDescription)"
                )
            }
        }
        #expect(
            failures.isEmpty,
            "normalize conformance FAILED: \(failures.count)/\(vectors.count) diverge:\n\(failures.joined(separator: "\n"))"
        )
    }
}

// MARK: - Tag conformance

private struct TagVector: Decodable {
    let token: String
    let `class`: String
}

@Suite("HMM tagger Swift/Rust conformance vectors")
struct TagConformanceTests {

    private func loadVectors() throws -> [TagVector] {
        let fixtureURL = LanguageFixtures.url("tag_conformance.json")
        let data = try #require(
            try? Data(contentsOf: fixtureURL),
            "tag_conformance.json must be readable at \(fixtureURL.path)"
        )
        return try JSONDecoder().decode([TagVector].self, from: data)
    }

    private func name(_ c: WordClass) -> String {
        switch c {
        case .noun: return "noun"
        case .verb: return "verb"
        case .other: return "other"
        }
    }

    @Test("all tag vectors match")
    func allTagVectorsMatch() throws {
        let vectors = try loadVectors()
        #expect(!vectors.isEmpty, "fixture must contain at least one vector")

        var failures: [String] = []
        for v in vectors {
            let got = name(HMMTagger.tag(v.token))
            if got != v.class {
                failures.append(
                    "MISMATCH token=\(v.token.debugDescription) expected=\(v.class.debugDescription) got=\(got.debugDescription)"
                )
            }
        }
        #expect(
            failures.isEmpty,
            "tag conformance FAILED: \(failures.count)/\(vectors.count) diverge:\n\(failures.joined(separator: "\n"))"
        )
    }
}
