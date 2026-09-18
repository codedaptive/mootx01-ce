import Testing
import Foundation
@testable import mcp_benchmarker

// MemBenchCorpusTests.swift — Unit tests for the MemBench corpus loader.
//
// All tests use the hand-authored synthetic fixture at membench_sample.json;
// no real dataset rows are committed to the repo.
//
// Fixture schema mirrors the verified real dataset schema (2026-08-06):
//   top-level key "roles" → array of {tid, message_list, QA} items
//   target_step_id = [[global_sid, session_idx]]

@Suite("MemBench corpus loader")
struct MemBenchCorpusTests {

    // MARK: - Helpers

    private func sampleURL() -> URL {
        // membench_sample.json is committed to the repository alongside this test.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("membench_sample.json")
    }

    /// Writes a temporary MemBench JSON file for edge-case tests.
    private func tmpURL(content: String) throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/membench_test_\(UUID()).json")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Directory structure helper

    /// Creates a minimal MemData/FirstAgent/ tree containing the fixture file.
    private func fixtureDataDir() throws -> URL {
        let baseDir = URL(fileURLWithPath: "/tmp/membench_datadir_\(UUID())")
        let agentDir = baseDir.appendingPathComponent("FirstAgent")
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
        // Copy the sample fixture as "simple.json".
        let fixtureURL = sampleURL()
        try FileManager.default.copyItem(at: fixtureURL,
                                         to: agentDir.appendingPathComponent("simple.json"))
        return baseDir
    }

    // MARK: - Basic load from directory

    @Test("loads the synthetic sample with 2 items and 0 skipped")
    func loadsSyntheticSample() throws {
        let dataDir = try fixtureDataDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let corpus = try loadMemBenchCorpus(
            dataDir: dataDir,
            agent: "FirstAgent",
            categories: ["simple"]
        )

        // Fixture has 2 items with QA; both should load.
        #expect(corpus.items.count == 2, "expected 2 items from fixture")
        #expect(corpus.skippedCount == 0, "no items should be skipped")
        #expect(corpus.totalCount == 2, "totalCount = items + skipped")
    }

    // MARK: - Item fields

    @Test("item has correct category, agent, topic key, tid, and itemID")
    func itemFields() throws {
        let dataDir = try fixtureDataDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let corpus = try loadMemBenchCorpus(
            dataDir: dataDir,
            agent: "FirstAgent",
            categories: ["simple"]
        )
        let item = corpus.items[0]

        #expect(item.category == "simple")
        #expect(item.agent == "FirstAgent")
        #expect(item.topicKey == "roles")
        #expect(item.tid == 0)
        #expect(item.itemID.contains("simple"), "itemID should contain category")
    }

    // MARK: - Session structure

    @Test("item 0 has 2 sessions, item 1 has 1 session")
    func sessionCounts() throws {
        let dataDir = try fixtureDataDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let corpus = try loadMemBenchCorpus(
            dataDir: dataDir,
            agent: "FirstAgent",
            categories: ["simple"]
        )
        // Item 0 has 2 sessions; item 1 has 1 session.
        #expect(corpus.items[0].sessions.count == 2, "item 0 should have 2 sessions")
        #expect(corpus.items[1].sessions.count == 1, "item 1 should have 1 session")
    }

    @Test("sessions carry correct sessionIndex values")
    func sessionIndices() throws {
        let dataDir = try fixtureDataDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let corpus = try loadMemBenchCorpus(
            dataDir: dataDir,
            agent: "FirstAgent",
            categories: ["simple"]
        )
        let item0 = corpus.items[0]
        #expect(item0.sessions[0].sessionIndex == 0, "first session index should be 0")
        #expect(item0.sessions[1].sessionIndex == 1, "second session index should be 1")
    }

    @Test("turns carry correct sid values per session")
    func turnSids() throws {
        let dataDir = try fixtureDataDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let corpus = try loadMemBenchCorpus(
            dataDir: dataDir,
            agent: "FirstAgent",
            categories: ["simple"]
        )
        let item0 = corpus.items[0]
        // Item 0 session 0: sids 0, 1; session 1: sids 2, 3
        let s0sids = item0.sessions[0].turns.map(\.sid)
        #expect(s0sids == [0, 1], "item 0 session 0 sids should be [0, 1]")
        let s1sids = item0.sessions[1].turns.map(\.sid)
        #expect(s1sids == [2, 3], "item 0 session 1 sids should be [2, 3]")
    }

    @Test("allTurns flattens all sessions with correct count and ordering")
    func allTurnsFlattened() throws {
        let dataDir = try fixtureDataDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let corpus = try loadMemBenchCorpus(
            dataDir: dataDir,
            agent: "FirstAgent",
            categories: ["simple"]
        )
        let item0 = corpus.items[0]
        // Item 0 has 2 sessions × 2 turns each = 4 turns total.
        #expect(item0.allTurns.count == 4, "item 0 should have 4 turns total")
        #expect(item0.allTurns.first?.sid == 0, "first turn sid should be 0")
        #expect(item0.allTurns.last?.sid == 3, "last turn sid should be 3")
    }

    // MARK: - QA fields

    @Test("QA fields are all non-empty")
    func qaFields() throws {
        let dataDir = try fixtureDataDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let corpus = try loadMemBenchCorpus(
            dataDir: dataDir,
            agent: "FirstAgent",
            categories: ["simple"]
        )
        let qa = corpus.items[0].qa

        #expect(!qa.question.isEmpty, "question should be non-empty")
        #expect(!qa.answer.isEmpty, "answer should be non-empty")
        #expect(!qa.groundTruth.isEmpty, "ground_truth should be non-empty")
        #expect(!qa.choices.isEmpty, "choices should be non-empty")
    }

    @Test("target_step_id parses to globalSid=0, sessionIdx=0")
    func targetStepIDParsed() throws {
        let dataDir = try fixtureDataDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let corpus = try loadMemBenchCorpus(
            dataDir: dataDir,
            agent: "FirstAgent",
            categories: ["simple"]
        )
        // Item 0 target_step_id = [[0, 0]] → globalSid=0, sessionIdx=0
        let targetSteps = corpus.items[0].qa.targetStepID
        #expect(targetSteps.count == 1, "item 0 should have 1 target_step_id pair")
        #expect(targetSteps[0].globalSid == 0, "globalSid should be 0")
        #expect(targetSteps[0].sessionIdx == 0, "sessionIdx should be 0")
    }

    @Test("evidenceSids returns string representation of globalSid")
    func evidenceSids() throws {
        let dataDir = try fixtureDataDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let corpus = try loadMemBenchCorpus(
            dataDir: dataDir,
            agent: "FirstAgent",
            categories: ["simple"]
        )
        // evidenceSids = ["0"] for item 0 (globalSid=0 → "0")
        let evidence = corpus.items[0].evidenceSids
        #expect(evidence == ["0"], "evidenceSids should be [\"0\"] for globalSid=0")
    }

    // MARK: - Limit

    @Test("limit=1 caps corpus to 1 item")
    func limitApplied() throws {
        let dataDir = try fixtureDataDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let corpus = try loadMemBenchCorpus(
            dataDir: dataDir,
            agent: "FirstAgent",
            categories: ["simple"],
            limit: 1
        )
        #expect(corpus.items.count == 1, "limit=1 should return only 1 item")
    }

    @Test("limit larger than corpus size returns all items")
    func limitLargerThanCorpus() throws {
        let dataDir = try fixtureDataDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let corpus = try loadMemBenchCorpus(
            dataDir: dataDir,
            agent: "FirstAgent",
            categories: ["simple"],
            limit: 100
        )
        // Fixture has 2 items; limit larger than that should return all items.
        #expect(corpus.items.count == 2, "limit > corpus size should return all items")
    }

    // MARK: - Missing category file

    @Test("missing category file returns empty corpus without throwing")
    func missingCategoryFileSkipped() throws {
        let dataDir = try fixtureDataDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }

        // Request "noisy" which doesn't exist in the fixture dir.
        let corpus = try loadMemBenchCorpus(
            dataDir: dataDir,
            agent: "FirstAgent",
            categories: ["noisy"]
        )
        // Should return empty corpus without throwing.
        #expect(corpus.items.count == 0)
        #expect(corpus.skippedCount == 0)
    }

    // MARK: - Missing agent directory

    @Test("missing agent directory throws MemBenchLoadError")
    func missingAgentDirectoryThrows() throws {
        let baseDir = URL(fileURLWithPath: "/tmp/membench_empty_\(UUID())")
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }

        #expect {
            try loadMemBenchCorpus(dataDir: baseDir, agent: "FirstAgent", categories: ["simple"])
        } throws: { error in
            error is MemBenchLoadError
        }
    }

    // MARK: - Malformed JSON

    @Test("malformed JSON file throws MemBenchLoadError")
    func malformedJSONThrows() throws {
        let baseDir = URL(fileURLWithPath: "/tmp/membench_malformed_\(UUID())")
        let agentDir = baseDir.appendingPathComponent("FirstAgent")
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }
        try "not valid json".write(
            to: agentDir.appendingPathComponent("simple.json"),
            atomically: true, encoding: .utf8)

        #expect {
            try loadMemBenchCorpus(dataDir: baseDir, agent: "FirstAgent", categories: ["simple"])
        } throws: { error in
            error is MemBenchLoadError
        }
    }

    // MARK: - Items with no QA are skipped

    @Test("items with no QA field are skipped and counted in skippedCount")
    func itemsWithNoQASkipped() throws {
        let json = """
        {
          "roles": [
            {
              "tid": 0,
              "message_list": [[
                {"sid": 0, "user_message": "hi", "assistant_message": "hello",
                 "time": "2024-01-01T00:00:00Z", "place": "home"}
              ]]
            }
          ]
        }
        """
        let baseDir = URL(fileURLWithPath: "/tmp/membench_noqa_\(UUID())")
        let agentDir = baseDir.appendingPathComponent("FirstAgent")
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }
        try json.write(
            to: agentDir.appendingPathComponent("simple.json"),
            atomically: true, encoding: .utf8)

        let corpus = try loadMemBenchCorpus(
            dataDir: baseDir,
            agent: "FirstAgent",
            categories: ["simple"]
        )
        #expect(corpus.items.count == 0, "item without QA should be skipped")
        #expect(corpus.skippedCount == 1, "skipped count should be 1")
    }
}
