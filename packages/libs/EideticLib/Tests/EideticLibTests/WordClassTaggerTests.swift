// WordClassTaggerTests.swift
//
// Tests for FDC encoder Step 1 (cookbook §2): the shared-vector
// conformance gate for EideticLib.wordClass(_:), the min_os_version
// gate, and the novel-token cache submit-and-purge cycle. The shared
// vectors at ../SharedVectors/word_class_vectors.json are the same
// file the Rust port reads; any divergence between ports is a hard
// conformance failure.

import XCTest
@testable import EideticLib

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

final class WordClassSharedVectorTests: XCTestCase {

    private func loadVectors() throws -> WordClassVectorFile {
        // The test target copies ../SharedVectors as a directory
        // (Package.swift `.copy("../SharedVectors")`), so the file
        // lives under the SharedVectors subdirectory of the bundle.
        let url = try XCTUnwrap(
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

    func testSharedVectorSchemaIsOne() throws {
        let file = try loadVectors()
        XCTAssertEqual(file.schemaVersion, "1")
        XCTAssertFalse(
            file.vectors.isEmpty,
            "shared vectors file must carry at least one vector"
        )
    }

    /// Every shared vector resolves to its expected WordClass. This is
    /// the Swift half of the cross-port conformance gate; the Rust
    /// port asserts the same file.
    func testAllSharedVectorsMatch() throws {
        let file = try loadVectors()
        var failures: [String] = []
        for vector in file.vectors {
            let actual = EideticLib.wordClass(vector.input)
            if actual != vector.expected {
                failures.append(
                    "\(vector.id): expected \(vector.expected) got \(actual)"
                )
            }
        }
        XCTAssertTrue(
            failures.isEmpty,
            "Shared-vector conformance failures:\n"
                + failures.joined(separator: "\n")
        )
    }

    // Test Requirements coverage, called out explicitly.

    func testTableResidentNoun() {
        XCTAssertEqual(EideticLib.wordClass("dinner"), .noun)
    }

    func testTableResidentVerb() {
        XCTAssertEqual(EideticLib.wordClass("run"), .verb)
    }

    /// A preposition that must NOT be in the table falls to the tagger
    /// and resolves to .other.
    func testTablePrepositionFallsToTaggerAsOther() {
        XCTAssertFalse(WordClassTableCache.nounSet.contains("with"))
        XCTAssertFalse(WordClassTableCache.verbSet.contains("with"))
        XCTAssertEqual(EideticLib.wordClass("with"), .other)
    }

    func testEmptyTokenIsOther() {
        XCTAssertEqual(EideticLib.wordClass(""), .other)
    }

    /// Verb-then-noun ordering: "run" is in both sets, so it resolves
    /// to .verb (cookbook §2.1, mission Part 2 ordering).
    func testVerbPrecedesNounForTokenInBothSets() {
        XCTAssertTrue(WordClassTableCache.verbSet.contains("run"))
        XCTAssertTrue(WordClassTableCache.nounSet.contains("run"))
        XCTAssertEqual(EideticLib.wordClass("run"), .verb)
    }
}

final class WordClassMinOSGateTests: XCTestCase {

    /// Below the table's pinned min_os_version, the gate disables the
    /// tagger (table-only path). Tested directly with a synthetic OS
    /// version so no actual old OS is required (Test Requirements).
    func testGateDisabledBelowMinOSVersion() {
        let belowMin = OperatingSystemVersion(
            majorVersion: 16, minorVersion: 9, patchVersion: 0
        )
        XCTAssertFalse(
            EideticLib.taggerEnabled(osVersion: belowMin, minOSVersion: "17.0")
        )
    }

    func testGateEnabledAtAndAboveMinOSVersion() {
        let atMin = OperatingSystemVersion(
            majorVersion: 17, minorVersion: 0, patchVersion: 0
        )
        let aboveMin = OperatingSystemVersion(
            majorVersion: 18, minorVersion: 2, patchVersion: 1
        )
        XCTAssertTrue(
            EideticLib.taggerEnabled(osVersion: atMin, minOSVersion: "17.0")
        )
        XCTAssertTrue(
            EideticLib.taggerEnabled(osVersion: aboveMin, minOSVersion: "17.0")
        )
    }

    /// An unparseable min version fails closed (table only).
    func testGateFailsClosedOnUnparseableMinVersion() {
        let any = OperatingSystemVersion(
            majorVersion: 99, minorVersion: 0, patchVersion: 0
        )
        XCTAssertFalse(
            EideticLib.taggerEnabled(osVersion: any, minOSVersion: "")
        )
    }
}

final class NovelTokenCacheTests: XCTestCase {

    /// 49 entries do not submit; the 50th submits and drains, and the
    /// injected submitter receives a §2.3 payload with exactly 50
    /// entries. The cache is empty afterward.
    func testSubmitAndPurgeAtExactlyFifty() {
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
        XCTAssertNil(captured.value, "must not submit before 50 entries")
        XCTAssertEqual(cache.count, 49)

        cache.record(token: "novel49", wordClass: .verb)

        let submission = captured.value
        XCTAssertNotNil(submission, "must submit at exactly 50 entries")
        XCTAssertEqual(submission?.entries.count, 50)
        XCTAssertEqual(submission?.tableVersion, "1.0.0")
        XCTAssertEqual(submission?.platform, "apple")
        XCTAssertEqual(submission?.taggerVersion, "17.0.0")
        XCTAssertEqual(submission?.entries.first?.token, "novel0")
        XCTAssertEqual(submission?.entries.first?.tag, "NOUN")
        XCTAssertEqual(submission?.entries.last?.tag, "VERB")
        XCTAssertEqual(cache.count, 0, "cache must drain after submission")
    }

    /// The §2.3 wire format encodes with the pinned snake_case keys.
    func testWireFormatKeys() throws {
        let submission = PoolSubmission(
            tableVersion: "1.0.0",
            platform: "other",
            taggerVersion: "hmm-viterbi-stub-0",
            entries: [PoolEntry(token: "carburetor", tag: "NOUN")]
        )
        let data = try JSONEncoder().encode(submission)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"table_version\""))
        XCTAssertTrue(json.contains("\"tagger_version\""))
        XCTAssertTrue(json.contains("\"platform\""))
        XCTAssertTrue(json.contains("\"entries\""))
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
