import Testing
import Foundation
@testable import mcp_benchmarker

// LMEBCorpusTests — unit tests for the LMEB/ConvoMem corpus loader.
//
// All tests run against the hand-authored synthetic sample committed in this
// same Tests/ directory under lmeb_sample/user_evidence/. No real LMEB dataset
// rows enter the repository.
//
// The synthetic sample contains:
//   5 corpus docs (2 scenes: scene_0 with 3 turns, scene_1 with 2 turns)
//   2 queries (scene_0_q_0, scene_1_q_0)
//
// Ids carry their evidence type: ConvoMem numbers scenes from zero inside
// every category, so the loader namespaces them at load and the ids seen
// here are `user_evidence__scene_0_q_0` rather than the raw file value.
//   2 scene candidate pools
//   3 qrels (scene_0_q_0 → 2 docs, scene_1_q_0 → 1 doc)

// MARK: - Path helpers

/// Resolves the synthetic sample base directory from the test file's location.
///   .../Tests/mcp-benchmarkerTests/LMEBCorpusTests.swift
///     → mcp-benchmarkerTests/
///     → lmeb_sample/
private func sampleBaseDir(file: String = #filePath) -> URL {
    URL(fileURLWithPath: file)
        .deletingLastPathComponent()          // mcp-benchmarkerTests/
        .appendingPathComponent("lmeb_sample")
}

/// Loads the synthetic sample corpus (user_evidence only).
private func loadSample(file: String = #filePath) throws -> LMEBCorpus {
    try loadLMEBCorpus(
        baseDir: sampleBaseDir(file: file),
        evidenceTypes: ["user_evidence"]
    )
}

// MARK: - Tests

@Suite("LMEB corpus loader")
struct LMEBCorpusTests {

    // MARK: Happy path — counts

    @Test("loads sample and yields correct counts")
    func loadsSampleCounts() throws {
        let corpus = try loadSample()
        #expect(corpus.docCount == 5,   "expected 5 corpus docs")
        #expect(corpus.queryCount == 2, "expected 2 queries")
        #expect(corpus.qrelCount == 3,  "expected 3 qrel entries total")
    }

    // MARK: Happy path — doc contents

    @Test("loaded corpus docs have correct id / text / title")
    func docContents() throws {
        let corpus = try loadSample()
        let doc = try #require(corpus.docsByID["user_evidence__scene_0_session_1_turn_1"])
        #expect(doc.id == "user_evidence__scene_0_session_1_turn_1")
        #expect(doc.text.contains("Victorian rocking chair"),
                "turn 1 text should mention the rocking chair")
        #expect(doc.title == "Session 1, Turn 1")
    }

    // MARK: Happy path — query contents

    @Test("loaded queries have correct id / text")
    func queryContents() throws {
        let corpus = try loadSample()
        let q = try #require(corpus.queriesByID["user_evidence__scene_0_q_0"])
        #expect(q.id == "user_evidence__scene_0_q_0")
        #expect(q.text.contains("furniture"), "query should mention 'furniture'")
    }

    // MARK: Happy path — candidateDocs lookup

    @Test("candidateDocs returns correct pool for scene_0_q_0")
    func candidateDocsScene0() throws {
        let corpus = try loadSample()
        let cands = corpus.candidateDocs(forQuery: "user_evidence__scene_0_q_0")
        #expect(cands.count == 3, "scene_0 should have 3 candidates")
        #expect(cands.contains("user_evidence__scene_0_session_1_turn_1"))
        #expect(cands.contains("user_evidence__scene_0_session_1_turn_3"))
    }

    @Test("candidateDocs returns correct pool for scene_1_q_0")
    func candidateDocsScene1() throws {
        let corpus = try loadSample()
        let cands = corpus.candidateDocs(forQuery: "user_evidence__scene_1_q_0")
        #expect(cands.count == 2, "scene_1 should have 2 candidates")
    }

    @Test("candidateDocs returns empty array for unknown query")
    func candidateDocsUnknown() throws {
        let corpus = try loadSample()
        let cands = corpus.candidateDocs(forQuery: "user_evidence__scene_999_q_0")
        #expect(cands.isEmpty, "unknown scene should return empty array")
    }

    // MARK: Happy path — relevantDocs lookup

    @Test("relevantDocs returns correct set for scene_0_q_0 (2 relevant docs)")
    func relevantDocsScene0() throws {
        let corpus = try loadSample()
        let rel = corpus.relevantDocs(forQuery: "user_evidence__scene_0_q_0")
        #expect(rel.count == 2, "scene_0_q_0 has 2 relevant docs")
        #expect(rel.contains("user_evidence__scene_0_session_1_turn_1"))
        #expect(rel.contains("user_evidence__scene_0_session_1_turn_3"))
        #expect(!rel.contains("user_evidence__scene_0_session_1_turn_2"), "turn_2 is not relevant")
    }

    @Test("relevantDocs returns correct set for scene_1_q_0 (1 relevant doc)")
    func relevantDocsScene1() throws {
        let corpus = try loadSample()
        let rel = corpus.relevantDocs(forQuery: "user_evidence__scene_1_q_0")
        #expect(rel.count == 1)
        #expect(rel.contains("user_evidence__scene_1_session_1_turn_1"))
    }

    @Test("relevantDocs returns empty set for query with no qrels")
    func relevantDocsUnknown() throws {
        let corpus = try loadSample()
        let rel = corpus.relevantDocs(forQuery: "user_evidence__scene_999_q_0")
        #expect(rel.isEmpty)
    }

    // MARK: Happy path — scene ID extraction

    @Test("candidateDocs extracts scene ID correctly for _q_ suffix")
    func sceneIDExtraction() throws {
        let corpus = try loadSample()
        // "user_evidence__scene_0_q_0" → scene_id "scene_0"
        let pool0 = corpus.candidateDocs(forQuery: "user_evidence__scene_0_q_0")
        // "user_evidence__scene_1_q_0" → scene_id "scene_1"
        let pool1 = corpus.candidateDocs(forQuery: "user_evidence__scene_1_q_0")
        #expect(pool0.count == 3)
        #expect(pool1.count == 2)
    }

    // MARK: Schema validation errors

    @Test("corpus row with empty id raises LMEBLoadError")
    func emptyCorpusID() throws {
        let badJSONL = """
        {"id": "", "text": "some text", "title": "Turn 1"}
        """.data(using: .utf8)!

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lmeb_test_bad_corpus.jsonl")
        try badJSONL.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Build a temp directory with the bad file
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lmeb_test_bad_dir_\(UUID().uuidString)")
        let etDir = tmpDir.appendingPathComponent("user_evidence")
        try FileManager.default.createDirectory(
            at: etDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try badJSONL.write(to: etDir.appendingPathComponent("corpus.jsonl"))

        // queries.jsonl, candidates.jsonl, qrels.tsv must exist for the loader to
        // reach the corpus row check — provide valid minimal versions.
        try "{}".data(using: .utf8)!
            .write(to: etDir.appendingPathComponent("queries.jsonl"))
        try "{}".data(using: .utf8)!
            .write(to: etDir.appendingPathComponent("candidates.jsonl"))
        try "".data(using: .utf8)!
            .write(to: etDir.appendingPathComponent("qrels.tsv"))

        do {
            _ = try loadLMEBCorpus(baseDir: tmpDir, evidenceTypes: ["user_evidence"])
            Issue.record("expected LMEBLoadError for empty corpus id, got success")
        } catch let err as LMEBLoadError {
            #expect(err.description.contains("'id'"),
                    "error should name the 'id' field: \(err.description)")
        }
    }

    @Test("qrels TSV line with single field raises LMEBLoadError")
    func malformedQrelsLine() throws {
        let singleFieldTSV = "scene_0_q_0\n".data(using: .utf8)!
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lmeb_test_bad_qrels_\(UUID().uuidString)")
        let etDir = tmpDir.appendingPathComponent("user_evidence")
        try FileManager.default.createDirectory(
            at: etDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Valid stub corpus, queries, candidates — only qrels is malformed.
        let validDoc = """
        {"id": "doc1", "text": "t", "title": "T"}
        """.data(using: .utf8)!
        let validQuery = """
        {"id": "q1", "text": "question?"}
        """.data(using: .utf8)!
        let validCand = """
        {"scene_id": "scene_0", "candidate_doc_ids": ["doc1"]}
        """.data(using: .utf8)!

        try validDoc.write(to: etDir.appendingPathComponent("corpus.jsonl"))
        try validQuery.write(to: etDir.appendingPathComponent("queries.jsonl"))
        try validCand.write(to: etDir.appendingPathComponent("candidates.jsonl"))
        try singleFieldTSV.write(to: etDir.appendingPathComponent("qrels.tsv"))

        do {
            _ = try loadLMEBCorpus(baseDir: tmpDir, evidenceTypes: ["user_evidence"])
            Issue.record("expected LMEBLoadError for malformed qrels, got success")
        } catch let err as LMEBLoadError {
            #expect(err.description.contains("tab-separated"),
                    "error should mention tab-separated fields: \(err.description)")
        }
    }

    @Test("load from missing evidence type directory throws")
    func missingDirectory() {
        let baseDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lmeb_no_such_dir_\(UUID().uuidString)")
        #expect(throws: (any Error).self) {
            try loadLMEBCorpus(baseDir: baseDir, evidenceTypes: ["user_evidence"])
        }
    }

    // MARK: Empty-corpus edge case

    @Test("empty evidence type directory loads successfully with zero counts")
    func emptyEvidenceType() throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lmeb_test_empty_\(UUID().uuidString)")
        let etDir = tmpDir.appendingPathComponent("user_evidence")
        try FileManager.default.createDirectory(
            at: etDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // All four files present but empty (or whitespace-only).
        try "".data(using: .utf8)!.write(to: etDir.appendingPathComponent("corpus.jsonl"))
        try "".data(using: .utf8)!.write(to: etDir.appendingPathComponent("queries.jsonl"))
        try "".data(using: .utf8)!.write(to: etDir.appendingPathComponent("candidates.jsonl"))
        try "".data(using: .utf8)!.write(to: etDir.appendingPathComponent("qrels.tsv"))

        let corpus = try loadLMEBCorpus(baseDir: tmpDir, evidenceTypes: ["user_evidence"])
        #expect(corpus.docCount == 0)
        #expect(corpus.queryCount == 0)
        #expect(corpus.qrelCount == 0)
    }
}

// MARK: - lmebCorpusDigest tests

// Fixture file contents for the cross-port golden pin.
// Every file ends with a trailing newline. Lines separated by \n only. No BOM, no CRLF.
private let pinCorpus =
    "{\"id\":\"d0\",\"text\":\"alpha\",\"title\":\"A\"}\n" +
    "{\"id\":\"d1\",\"text\":\"beta\",\"title\":\"B\"}\n"
private let pinQueries = "{\"id\":\"q0\",\"text\":\"who is alpha\"}\n"
private let pinCandidates = "{\"scene_id\":\"s0\",\"candidate_doc_ids\":[\"d0\",\"d1\"]}\n"
private let pinQrels = "q0\td0\t1\n" // real tab character, \n line ending

/// Writes the four golden-pin fixture files under {tmpDir}/user_evidence/.
private func writePinFixture(to tmpDir: URL) throws {
    let etDir = tmpDir.appendingPathComponent("user_evidence")
    try FileManager.default.createDirectory(at: etDir, withIntermediateDirectories: true)
    try pinCorpus.data(using: .utf8)!.write(to: etDir.appendingPathComponent("corpus.jsonl"))
    try pinQueries.data(using: .utf8)!.write(to: etDir.appendingPathComponent("queries.jsonl"))
    try pinCandidates.data(using: .utf8)!.write(to: etDir.appendingPathComponent("candidates.jsonl"))
    try pinQrels.data(using: .utf8)!.write(to: etDir.appendingPathComponent("qrels.tsv"))
}

@Suite("lmebCorpusDigest")
struct LMEBCorpusDigestTests {

    // MARK: (a) Cross-port golden pin

    @Test("(a) cross-port golden pin: fixture produces pinned hex literal")
    func crossPortGoldenPin() throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lmeb_digest_pin_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try writePinFixture(to: tmpDir)

        let digest = lmebCorpusDigest(baseDir: tmpDir, evidenceTypes: ["user_evidence"])

        // cross-port pin — this literal also appears in lmeb_corpus.rs (digest_cross_port_golden_pin);
        // if you change one you must change the other, and if they ever disagree the ports have diverged.
        #expect(
            digest == "b8702013f1d2aecf31110b3c034f58809c6a447fa2bb6e163bfd64929dc4c240",
            "cross-port golden pin mismatch — update both Swift and Rust literals together"
        )
    }

    // MARK: (b) Content sensitivity

    @Test("(b) different corpus.jsonl content produces different digest")
    func contentSensitivity() throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lmeb_digest_content_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try writePinFixture(to: tmpDir)

        let digestA = lmebCorpusDigest(baseDir: tmpDir, evidenceTypes: ["user_evidence"])

        // Overwrite corpus.jsonl with different content; all other files unchanged.
        let different = "{\"id\":\"d0\",\"text\":\"completely different\",\"title\":\"X\"}\n"
        try different.data(using: .utf8)!.write(
            to: tmpDir.appendingPathComponent("user_evidence/corpus.jsonl"))

        let digestB = lmebCorpusDigest(baseDir: tmpDir, evidenceTypes: ["user_evidence"])

        #expect(digestA != digestB, "different corpus.jsonl content must produce different digests")
        // Neither should be "unknown" — both corpora are fully readable.
        #expect(digestA != "unknown")
        #expect(digestB != "unknown")
    }

    // MARK: (c) Explicit failure

    @Test("(c) missing required file returns the literal string 'unknown'")
    func explicitFailureMissingFile() throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lmeb_digest_missing_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try writePinFixture(to: tmpDir)

        // Remove qrels.tsv — one of the four required files.
        try FileManager.default.removeItem(
            at: tmpDir.appendingPathComponent("user_evidence/qrels.tsv"))

        let digest = lmebCorpusDigest(baseDir: tmpDir, evidenceTypes: ["user_evidence"])
        #expect(
            digest == "unknown",
            "any unreadable required file must return the literal 'unknown', not a hash"
        )
    }

    // MARK: (d) Empty evidence-type list

    @Test("(d) empty evidence-type list returns 'unknown'")
    func emptyEvidenceTypeList() throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lmeb_digest_empty_et_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let digest = lmebCorpusDigest(baseDir: tmpDir, evidenceTypes: [])
        #expect(digest == "unknown", "empty evidence-type list must return 'unknown'")
    }

    // MARK: (e) Multi-type order independence

    @Test("(e) same two evidence types in different argument order produce the same digest")
    func multiTypeOrderIndependence() throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lmeb_digest_multi_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Populate two evidence types with distinct content.
        let etADir = tmpDir.appendingPathComponent("evidence_a")
        try FileManager.default.createDirectory(at: etADir, withIntermediateDirectories: true)
        try "{\"id\":\"da\",\"text\":\"alpha doc\",\"title\":\"A\"}\n".data(using: .utf8)!
            .write(to: etADir.appendingPathComponent("corpus.jsonl"))
        try "{\"id\":\"qa\",\"text\":\"alpha query\"}\n".data(using: .utf8)!
            .write(to: etADir.appendingPathComponent("queries.jsonl"))
        try "{\"scene_id\":\"sa\",\"candidate_doc_ids\":[\"da\"]}\n".data(using: .utf8)!
            .write(to: etADir.appendingPathComponent("candidates.jsonl"))
        try "qa\tda\t1\n".data(using: .utf8)!
            .write(to: etADir.appendingPathComponent("qrels.tsv"))

        let etBDir = tmpDir.appendingPathComponent("evidence_b")
        try FileManager.default.createDirectory(at: etBDir, withIntermediateDirectories: true)
        try "{\"id\":\"db\",\"text\":\"beta doc\",\"title\":\"B\"}\n".data(using: .utf8)!
            .write(to: etBDir.appendingPathComponent("corpus.jsonl"))
        try "{\"id\":\"qb\",\"text\":\"beta query\"}\n".data(using: .utf8)!
            .write(to: etBDir.appendingPathComponent("queries.jsonl"))
        try "{\"scene_id\":\"sb\",\"candidate_doc_ids\":[\"db\"]}\n".data(using: .utf8)!
            .write(to: etBDir.appendingPathComponent("candidates.jsonl"))
        try "qb\tdb\t1\n".data(using: .utf8)!
            .write(to: etBDir.appendingPathComponent("qrels.tsv"))

        let digestAB = lmebCorpusDigest(baseDir: tmpDir, evidenceTypes: ["evidence_a", "evidence_b"])
        let digestBA = lmebCorpusDigest(baseDir: tmpDir, evidenceTypes: ["evidence_b", "evidence_a"])
        let digestAOnly = lmebCorpusDigest(baseDir: tmpDir, evidenceTypes: ["evidence_a"])
        let digestBOnly = lmebCorpusDigest(baseDir: tmpDir, evidenceTypes: ["evidence_b"])

        #expect(
            digestAB == digestBA,
            "argument order must not affect the digest (function sorts internally)"
        )
        #expect(
            digestAB != digestAOnly,
            "two-type digest must differ from single-type digest"
        )
        #expect(
            digestAB != digestBOnly,
            "two-type digest must differ from single-type digest"
        )
    }
}
