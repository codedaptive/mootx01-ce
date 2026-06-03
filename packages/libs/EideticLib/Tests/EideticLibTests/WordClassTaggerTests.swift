// WordClassTaggerTests.swift
//
// Tests for FDC encoder Step 1 (cookbook §2): the shared-vector
// conformance gate for LatticeLib.wordClass(_:), the min_os_version
// gate, and the novel-token cache submit-and-purge cycle. The shared
// vectors at ../SharedVectors/word_class_vectors.json are the same
// file the Rust port reads; any divergence between ports is a hard
// conformance failure.

import Testing
import Foundation
@testable import EideticLib
@testable import LatticeLib

/// One shared conformance vector (mirrors the Rust `Vector` struct).
private struct WordClassVector: Decodable {
    let id: String
    let input: String
    let expected: WordClass
    let path: String
}

private struct WordClassVectorFile: Decodable {
    let schemaVersion: String
    let vectors: [WordClassVector]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case vectors
    }
}

@Suite("Word-class shared-vector conformance")
struct WordClassSharedVectorTests {

    private func loadVectors() throws -> WordClassVectorFile {
        // The test target copies ../SharedVectors as a directory
        // (Package.swift `.copy("../SharedVectors")`), so the file
        // lives under the SharedVectors subdirectory of the bundle.
        let url = try #require(
            Bundle.module.url(
                forResource: "word_class_vectors",
                withExtension: "json",
                subdirectory: "SharedVectors"
            ),
            "word_class_vectors.json must ship in the test bundle"
        )
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(WordClassVectorFile.self, from: data)
    }

    @Test("shared-vector schema is one")
    func sharedVectorSchemaIsOne() throws {
        let file = try loadVectors()
        #expect(file.schemaVersion == "1")
        #expect(
            !file.vectors.isEmpty,
            "shared vectors file must carry at least one vector"
        )
    }

    /// Every shared vector resolves to its expected WordClass. This is
    /// the Swift half of the cross-leg conformance gate; the Rust
    /// port asserts the same file.
    @Test("all shared vectors match")
    func allSharedVectorsMatch() throws {
        let file = try loadVectors()
        var failures: [String] = []
        for vector in file.vectors {
            let actual = LatticeLib.wordClass(vector.input)
            if actual != vector.expected {
                failures.append(
                    "\(vector.id): expected \(vector.expected) got \(actual)"
                )
            }
        }
        #expect(
            failures.isEmpty,
            "Shared-vector conformance failures:\n\(failures.joined(separator: "\n"))"
        )
    }

    // Test Requirements coverage, called out explicitly.

    @Test("table-resident noun")
    func tableResidentNoun() {
        #expect(LatticeLib.wordClass("dinner") == .noun)
    }

    @Test("table-resident verb")
    func tableResidentVerb() {
        #expect(LatticeLib.wordClass("run") == .verb)
    }

    /// A preposition that must NOT be in the table falls to the tagger
    /// and resolves to .other.
    @Test("table preposition falls to tagger as other")
    func tablePrepositionFallsToTaggerAsOther() {
        #expect(!WordClassTableCache.nounSet.contains("with"))
        #expect(!WordClassTableCache.verbSet.contains("with"))
        #expect(LatticeLib.wordClass("with") == .other)
    }

    @Test("empty token is other")
    func emptyTokenIsOther() {
        #expect(LatticeLib.wordClass("") == .other)
    }

    /// Verb-then-noun ordering: "run" is in both sets, so it resolves
    /// to .verb (cookbook §2.1, mission Part 2 ordering).
    @Test("verb precedes noun for token in both sets")
    func verbPrecedesNounForTokenInBothSets() {
        #expect(WordClassTableCache.verbSet.contains("run"))
        #expect(WordClassTableCache.nounSet.contains("run"))
        #expect(LatticeLib.wordClass("run") == .verb)
    }
}

@Suite("Word-class min-OS gate")
struct WordClassMinOSGateTests {

    /// Below the table's pinned min_os_version, the gate disables the
    /// tagger (table-only path). Tested directly with a synthetic OS
    /// version so no actual old OS is required (Test Requirements).
    @Test("gate disabled below min OS version")
    func gateDisabledBelowMinOSVersion() {
        let belowMin = OperatingSystemVersion(
            majorVersion: 16, minorVersion: 9, patchVersion: 0
        )
        #expect(
            !LatticeLib.taggerEnabled(osVersion: belowMin, minOSVersion: "17.0")
        )
    }

    @Test("gate enabled at and above min OS version")
    func gateEnabledAtAndAboveMinOSVersion() {
        let atMin = OperatingSystemVersion(
            majorVersion: 17, minorVersion: 0, patchVersion: 0
        )
        let aboveMin = OperatingSystemVersion(
            majorVersion: 18, minorVersion: 2, patchVersion: 1
        )
        #expect(
            LatticeLib.taggerEnabled(osVersion: atMin, minOSVersion: "17.0")
        )
        #expect(
            LatticeLib.taggerEnabled(osVersion: aboveMin, minOSVersion: "17.0")
        )
    }

    /// An unparseable min version fails closed (table only).
    @Test("gate fails closed on unparseable min version")
    func gateFailsClosedOnUnparseableMinVersion() {
        let any = OperatingSystemVersion(
            majorVersion: 99, minorVersion: 0, patchVersion: 0
        )
        #expect(
            !LatticeLib.taggerEnabled(osVersion: any, minOSVersion: "")
        )
    }
}

@Suite("Novel-token cache")
struct NovelTokenCacheTests {

    /// 49 entries do not submit; the 50th submits and drains, and the
    /// injected submitter receives a §2.3 payload with exactly 50
    /// entries. The cache is empty afterward.
    @Test("submit and purge at exactly fifty")
    func submitAndPurgeAtExactlyFifty() {
        let captured = SubmissionBox()
        let cache = NovelTokenCache(
            tableVersion: "1.0.0",
            platform: "apple",
            taggerVersion: "17.0.0",
            submitter: { submission in captured.store(submission) }
        )

        for i in 0..<49 {
            cache.record(token: "novel\(i)", wordClass: .noun)
        }
        #expect(captured.value == nil, "must not submit before 50 entries")
        #expect(cache.count == 49)

        cache.record(token: "novel49", wordClass: .verb)

        let submission = captured.value
        #expect(submission != nil, "must submit at exactly 50 entries")
        #expect(submission?.entries.count == 50)
        #expect(submission?.tableVersion == "1.0.0")
        #expect(submission?.platform == "apple")
        #expect(submission?.taggerVersion == "17.0.0")
        #expect(submission?.entries.first?.token == "novel0")
        #expect(submission?.entries.first?.tag == "NOUN")
        #expect(submission?.entries.last?.tag == "VERB")
        #expect(cache.count == 0, "cache must drain after submission")
    }

    /// The §2.3 wire format encodes with the pinned snake_case keys.
    @Test("wire format keys")
    func wireFormatKeys() throws {
        let submission = PoolSubmission(
            tableVersion: "1.0.0",
            platform: "other",
            taggerVersion: "hmm-viterbi-stub-0",
            entries: [PoolEntry(token: "carburetor", tag: "NOUN")]
        )
        let data = try JSONEncoder().encode(submission)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"table_version\""))
        #expect(json.contains("\"tagger_version\""))
        #expect(json.contains("\"platform\""))
        #expect(json.contains("\"entries\""))
    }
}

/// A tiny thread-safe holder so the @Sendable submitter closure can
/// hand the captured submission back to the test.
private final class SubmissionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PoolSubmission?

    var value: PoolSubmission? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func store(_ submission: PoolSubmission) {
        lock.lock()
        stored = submission
        lock.unlock()
    }
}
