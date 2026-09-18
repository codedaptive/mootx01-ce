import Testing
import Foundation
import SQLite3
@testable import mcp_benchmarker

// PayloadEconomicsTests — pure-logic coverage for the payload lanes
// (payload-economics / synthesis-payload, run book §9). No live serve.
//
// The aggregation vector is a LITERAL twin of the Rust unit test
// payload_arm_cell_parity in benchmarks/rust/src/payload_economics.rs
// (dual-port conformance: same samples, same expected cell figures,
// asserted in both ports).

@Suite("Payload lanes")
struct PayloadEconomicsTests {

    // ── Aggregation (literal twin of the Rust payload_arm_cell_parity) ──────

    @Test func armCellAggregation() {
        // Four samples: tokens 100/300/200/400 (mean 250); evidence annotated
        // on two (one hit → rate 0.5); answers present on three (rate 0.75);
        // retrieval scored on all four (two hits → 0.5; RRs 1, 0.5, 0, 0.25 →
        // MRR 0.4375).
        let cell = aggregatePayloadArm([
            PayloadArmSample(tokens: 100, evidenceHit: true, answerPresent: true,
                             hitAtK: true, reciprocalRank: 1.0),
            PayloadArmSample(tokens: 300, evidenceHit: false, answerPresent: true,
                             hitAtK: true, reciprocalRank: 0.5),
            PayloadArmSample(tokens: 200, evidenceHit: nil, answerPresent: false,
                             hitAtK: false, reciprocalRank: 0.0),
            PayloadArmSample(tokens: 400, evidenceHit: nil, answerPresent: true,
                             hitAtK: false, reciprocalRank: 0.25),
        ])
        #expect(cell.n == 4)
        #expect(cell.meanTokens == 250.0)
        #expect(cell.evidenceHitRate == 0.5)
        // 0.5 / 250 × 1000 = 2.0 evidence hits per 1k tokens.
        #expect(cell.evidenceHitsPer1kTokens == 2.0)
        #expect(cell.answerPresenceRate == 0.75)
        // 0.75 / 250 × 1000 = 3.0.
        #expect(cell.answerPresencePer1kTokens == 3.0)
        #expect(cell.hitAtK == 0.5)
        #expect(cell.mrr == 0.4375)
    }

    @Test func armCellNoAnnotationsAndEmpty() {
        // No sample carries an evidence annotation → nil rate, nil per-1k;
        // answer figures still publish.
        let cell = aggregatePayloadArm([
            PayloadArmSample(tokens: 8, evidenceHit: nil, answerPresent: true,
                             hitAtK: nil, reciprocalRank: nil),
        ])
        #expect(cell.evidenceHitRate == nil)
        #expect(cell.evidenceHitsPer1kTokens == nil)
        #expect(cell.answerPresenceRate == 1.0)
        // Synth-style sample: no retrieval figures at all.
        #expect(cell.hitAtK == nil)
        #expect(cell.mrr == nil)

        let empty = aggregatePayloadArm([])
        #expect(empty.n == 0)
        #expect(empty.meanTokens == 0)
        #expect(empty.answerPresencePer1kTokens == nil)
    }

    // ── Question join ───────────────────────────────────────────────────────

    @Test func joinCarriesGoldAnswerAndFailsLoudOnMissing() throws {
        let artifactJSONL = """
        {"question_id": "q-1", "question_type": "multi-session", "persona": "Priya Calder", "question": "Where did I go?", "question_3p": "Where did Priya go?", "question_date": "2023-05-30", "answer": "Paris", "answer_session_ids": ["s-9"]}
        """
        let artifact = try loadArtifactRecallQuestions(
            jsonl: artifactJSONL, dataset: .lmeS)
        // LMETurn/LMEQuestion decode only (no memberwise init) — build the
        // official question through the real corpus loader.
        let corpusJSON = """
        [{"question_id": "q-1", "question_type": "multi-session",
          "question": "Where did I go?", "answer": "Paris",
          "question_date": "2023/05/30 (Tue) 10:00",
          "haystack_dates": ["2023/05/29 (Mon) 09:00"],
          "haystack_session_ids": ["s-9"],
          "haystack_sessions": [[{"role": "user",
                                  "content": "I flew to Paris yesterday.",
                                  "has_answer": true}]],
          "answer_session_ids": ["s-9"]}]
        """
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("payload-lane-test-\(UUID().uuidString).json")
        try Data(corpusJSON.utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let official = try loadLMECorpus(from: tmp).questions

        let joined = try joinPayloadLaneQuestions(
            artifact: artifact, official: official)
        #expect(joined.count == 1)
        // The 3rd-person seeding question is what gets asked.
        #expect(joined[0].question == "Where did Priya go?")
        #expect(joined[0].goldAnswer == "Paris")
        // has_answer turn text flows through for the evidence figure.
        #expect(joined[0].evidenceText == "I flew to Paris yesterday.")
        #expect(joined[0].answerSessionIDs == ["s-9"])

        // A question absent from the official corpus is a hard error, never
        // a silent drop (a truncated set must not score as complete).
        #expect(throws: MCPError.self) {
            _ = try joinPayloadLaneQuestions(artifact: artifact, official: [])
        }
    }
}


