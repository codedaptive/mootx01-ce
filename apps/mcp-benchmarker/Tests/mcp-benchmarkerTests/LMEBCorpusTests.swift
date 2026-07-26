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
        let doc = try #require(corpus.docsByID["scene_0_session_1_turn_1"])
        #expect(doc.id == "scene_0_session_1_turn_1")
        #expect(doc.text.contains("Victorian rocking chair"),
                "turn 1 text should mention the rocking chair")
        #expect(doc.title == "Session 1, Turn 1")
    }

    // MARK: Happy path — query contents

    @Test("loaded queries have correct id / text")
    func queryContents() throws {
        let corpus = try loadSample()
        let q = try #require(corpus.queriesByID["scene_0_q_0"])
        #expect(q.id == "scene_0_q_0")
        #expect(q.text.contains("furniture"), "query should mention 'furniture'")
    }

    // MARK: Happy path — candidateDocs lookup

    @Test("candidateDocs returns correct pool for scene_0_q_0")
    func candidateDocsScene0() throws {
        let corpus = try loadSample()
        let cands = corpus.candidateDocs(forQuery: "scene_0_q_0")
        #expect(cands.count == 3, "scene_0 should have 3 candidates")
        #expect(cands.contains("scene_0_session_1_turn_1"))
        #expect(cands.contains("scene_0_session_1_turn_3"))
    }

    @Test("candidateDocs returns correct pool for scene_1_q_0")
    func candidateDocsScene1() throws {
        let corpus = try loadSample()
        let cands = corpus.candidateDocs(forQuery: "scene_1_q_0")
        #expect(cands.count == 2, "scene_1 should have 2 candidates")
    }

    @Test("candidateDocs returns empty array for unknown query")
    func candidateDocsUnknown() throws {
        let corpus = try loadSample()
        let cands = corpus.candidateDocs(forQuery: "scene_999_q_0")
        #expect(cands.isEmpty, "unknown scene should return empty array")
    }

    // MARK: Happy path — relevantDocs lookup

    @Test("relevantDocs returns correct set for scene_0_q_0 (2 relevant docs)")
    func relevantDocsScene0() throws {
        let corpus = try loadSample()
        let rel = corpus.relevantDocs(forQuery: "scene_0_q_0")
        #expect(rel.count == 2, "scene_0_q_0 has 2 relevant docs")
        #expect(rel.contains("scene_0_session_1_turn_1"))
        #expect(rel.contains("scene_0_session_1_turn_3"))
        #expect(!rel.contains("scene_0_session_1_turn_2"), "turn_2 is not relevant")
    }

    @Test("relevantDocs returns correct set for scene_1_q_0 (1 relevant doc)")
    func relevantDocsScene1() throws {
        let corpus = try loadSample()
        let rel = corpus.relevantDocs(forQuery: "scene_1_q_0")
        #expect(rel.count == 1)
        #expect(rel.contains("scene_1_session_1_turn_1"))
    }

    @Test("relevantDocs returns empty set for query with no qrels")
    func relevantDocsUnknown() throws {
        let corpus = try loadSample()
        let rel = corpus.relevantDocs(forQuery: "scene_999_q_0")
        #expect(rel.isEmpty)
    }

    // MARK: Happy path — scene ID extraction

    @Test("candidateDocs extracts scene ID correctly for _q_ suffix")
    func sceneIDExtraction() throws {
        let corpus = try loadSample()
        // "scene_0_q_0" → scene_id "scene_0"
        let pool0 = corpus.candidateDocs(forQuery: "scene_0_q_0")
        // "scene_1_q_0" → scene_id "scene_1"
        let pool1 = corpus.candidateDocs(forQuery: "scene_1_q_0")
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
