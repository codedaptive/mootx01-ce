import Testing
import Foundation
@testable import mcp_benchmarker

// SynthesizeArmTests.swift — unit tests for the synthesize judged cell
// added by PR-08 Deliverable 3.
//
// Covers:
//   - LMESynthesizeCell Codable shape matches the snake_case contract
//   - LMEJudgeAccuracy carries a synthesize arm (additive to exact/dense)
//   - LMEQuestionResult carries synthesize payload + judge fields
//   - Default (synthesizeArm off) leaves all synthesize fields nil
//   - No retrieval metric: synthesize has only judge accuracy, not recall
//   - lmeAggregateJudgeAccuracy aggregates synthesize arm correctly
//
// No live MCP, no judge subprocess, no estate provisioning.

@Suite("Synthesize judged cell")
struct SynthesizeArmTests {

    // MARK: - LMESynthesizeCell encoding

    @Test("LMESynthesizeCell disabled encodes with enabled=false and nil metrics")
    func synthesizeCellDisabledEncoding() throws {
        let cell = LMESynthesizeCell(
            enabled: false, questionCount: 0, judgedCount: nil, accuracyRate: nil)
        let json = try encodeJSON(cell)
        #expect(json.contains("\"enabled\" : false"))
        #expect(json.contains("\"question_count\" : 0"))
        // nil fields must be absent (JSONEncoder skips nil Optionals by default).
        #expect(!json.contains("judged_count"))
        #expect(!json.contains("accuracy_rate"))
    }

    @Test("LMESynthesizeCell enabled encodes all metric fields")
    func synthesizeCellEnabledEncoding() throws {
        let cell = LMESynthesizeCell(
            enabled: true, questionCount: 50, judgedCount: 45, accuracyRate: 0.82)
        let json = try encodeJSON(cell)
        #expect(json.contains("\"enabled\" : true"))
        #expect(json.contains("\"question_count\" : 50"))
        #expect(json.contains("\"judged_count\" : 45"))
        #expect(json.contains("\"accuracy_rate\""))
    }

    @Test("LMESynthesizeCell CodingKeys use snake_case")
    func synthesizeCellSnakeCaseKeys() throws {
        let cell = LMESynthesizeCell(
            enabled: true, questionCount: 10, judgedCount: 10, accuracyRate: 0.5)
        let json = try encodeJSON(cell)
        #expect(json.contains("\"question_count\""))
        #expect(json.contains("\"judged_count\""))
        #expect(json.contains("\"accuracy_rate\""))
        #expect(!json.contains("\"questionCount\""))
        #expect(!json.contains("\"judgedCount\""))
        #expect(!json.contains("\"accuracyRate\""))
    }

    @Test("LMESynthesizeCell survives JSON round-trip")
    func synthesizeCellRoundTrip() throws {
        let original = LMESynthesizeCell(
            enabled: true, questionCount: 30, judgedCount: 28, accuracyRate: 0.714)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LMESynthesizeCell.self, from: data)
        #expect(decoded.enabled == original.enabled)
        #expect(decoded.questionCount == original.questionCount)
        #expect(decoded.judgedCount == original.judgedCount)
        if let orig = original.accuracyRate, let dec = decoded.accuracyRate {
            #expect(abs(orig - dec) < 1e-9)
        } else {
            #expect(decoded.accuracyRate == nil)
        }
    }

    @Test("LMESynthesizeCell disabled round-trip preserves nil metrics")
    func synthesizeCellDisabledRoundTrip() throws {
        let original = LMESynthesizeCell(
            enabled: false, questionCount: 0, judgedCount: nil, accuracyRate: nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LMESynthesizeCell.self, from: data)
        #expect(!decoded.enabled)
        #expect(decoded.questionCount == 0)
        #expect(decoded.judgedCount == nil)
        #expect(decoded.accuracyRate == nil)
    }

    // MARK: - LMEJudgeAccuracy synthesize arm

    @Test("LMEJudgeAccuracy synthesize arm is nil when arm not used")
    func judgeAccuracySynthesizeArmNilWhenOff() {
        let acc = LMEJudgeAccuracy(
            grading: "substring", exact: nil, dense: nil, synthesize: nil)
        #expect(acc.synthesize == nil)
    }

    @Test("LMEJudgeAccuracy carries synthesize arm accuracy")
    func judgeAccuracyCarriesSynthesizeArm() {
        let synthArm = LMEJudgeArmAccuracy(judged: 20, correct: 14, accuracy: 0.70)
        let acc = LMEJudgeAccuracy(
            grading: "substring",
            exact: nil, dense: nil,
            synthesize: synthArm)
        #expect(acc.synthesize != nil)
        #expect(acc.synthesize?.judged == 20)
        #expect(acc.synthesize?.correct == 14)
        if let a = acc.synthesize?.accuracy {
            #expect(abs(a - 0.70) < 1e-9)
        }
    }

    @Test("LMEJudgeAccuracy synthesize arm is additive to exact and dense")
    func judgeAccuracySynthesizeIsAdditive() {
        let exact = LMEJudgeArmAccuracy(judged: 50, correct: 40, accuracy: 0.80)
        let dense = LMEJudgeArmAccuracy(judged: 50, correct: 38, accuracy: 0.76)
        let synth = LMEJudgeArmAccuracy(judged: 50, correct: 42, accuracy: 0.84)
        let acc = LMEJudgeAccuracy(
            grading: "verdict", exact: exact, dense: dense, synthesize: synth)
        // All three arms coexist without clobbering each other.
        #expect(acc.exact?.correct == 40)
        #expect(acc.dense?.correct == 38)
        #expect(acc.synthesize?.correct == 42)
    }

    @Test("LMEJudgeAccuracy survives JSON round-trip with synthesize arm")
    func judgeAccuracyRoundTrip() throws {
        let acc = LMEJudgeAccuracy(
            grading: "substring",
            exact: LMEJudgeArmAccuracy(judged: 10, correct: 8, accuracy: 0.8),
            dense: nil,
            synthesize: LMEJudgeArmAccuracy(judged: 10, correct: 7, accuracy: 0.7))
        let data = try JSONEncoder().encode(acc)
        let decoded = try JSONDecoder().decode(LMEJudgeAccuracy.self, from: data)
        #expect(decoded.grading == "substring")
        #expect(decoded.exact?.correct == 8)
        #expect(decoded.dense == nil)
        #expect(decoded.synthesize?.correct == 7)
    }

    // MARK: - lmeAggregateJudgeAccuracy synthesize aggregation

    @Test("lmeAggregateJudgeAccuracy aggregates synthesize arm when data present")
    func aggregateSynthesizeArm() {
        let results = [
            makeMiniResult(synthesizeJudgeAnswer: "yes", synthesizeJudgeCorrect: true),
            makeMiniResult(synthesizeJudgeAnswer: "no",  synthesizeJudgeCorrect: false),
            makeMiniResult(synthesizeJudgeAnswer: "yes", synthesizeJudgeCorrect: true),
        ]
        let acc = lmeAggregateJudgeAccuracy(results, grading: .substring)
        #expect(acc != nil)
        #expect(acc?.synthesize?.judged == 3)
        #expect(acc?.synthesize?.correct == 2)
        if let a = acc?.synthesize?.accuracy {
            #expect(abs(a - 2.0/3.0) < 1e-9)
        }
    }

    @Test("lmeAggregateJudgeAccuracy synthesize arm is nil when no results have it")
    func aggregateSynthesizeArmNilWhenNoData() {
        let results = [
            makeMiniResult(synthesizeJudgeAnswer: nil, synthesizeJudgeCorrect: nil),
            makeMiniResult(synthesizeJudgeAnswer: nil, synthesizeJudgeCorrect: nil),
        ]
        // No judge answers at all → entire block is nil (no data to report).
        let acc = lmeAggregateJudgeAccuracy(results, grading: .substring)
        #expect(acc == nil || acc?.synthesize == nil)
    }

    // MARK: - LMEQuestionResult synthesize fields

    @Test("LMEQuestionResult synthesize fields are nil when arm is off")
    func questionResultSynthesizeFieldsNilByDefault() {
        let r = makeMiniResult()
        #expect(r.synthesizePayloadText == nil)
        #expect(r.synthesizeJudgeAnswer == nil)
        #expect(r.synthesizeJudgeCorrect == nil)
        #expect(r.synthesizeJudgeTokens == nil)
    }

    @Test("LMEQuestionResult carries synthesize payload when arm is on")
    func questionResultCarriesSynthesizePayload() {
        let r = makeMiniResult(
            synthesizePayloadText: "Alice lives in Paris.",
            synthesizeJudgeAnswer: "yes",
            synthesizeJudgeCorrect: true,
            synthesizeJudgeTokens: 5)
        #expect(r.synthesizePayloadText == "Alice lives in Paris.")
        #expect(r.synthesizeJudgeAnswer == "yes")
        #expect(r.synthesizeJudgeCorrect == true)
        #expect(r.synthesizeJudgeTokens == 5)
    }

    // MARK: - No retrieval metric invariant

    @Test("LMESynthesizeCell has no recall metric fields")
    func synthesizeCellHasNoRecallFields() {
        // moot_synthesize generates a direct answer without ranked IDs; there
        // is no recall@k or MRR to score. This test documents that invariant
        // by verifying the struct's stored properties via Mirror.
        let cell = LMESynthesizeCell(
            enabled: true, questionCount: 10, judgedCount: 9, accuracyRate: 0.6)
        let fieldNames = Set(Mirror(reflecting: cell).children.compactMap(\.label))
        #expect(fieldNames.contains("enabled"))
        #expect(fieldNames.contains("questionCount"))
        #expect(fieldNames.contains("judgedCount"))
        #expect(fieldNames.contains("accuracyRate"))
        // Retrieval metrics must not be present.
        #expect(!fieldNames.contains("recallAtK"))
        #expect(!fieldNames.contains("mrr"))
        #expect(!fieldNames.contains("rankedIDs"))
    }
}

// MARK: - Helpers

private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try String(decoding: encoder.encode(value), as: UTF8.self)
}

/// Builds a minimal LMEQuestionResult with only the synthesize fields
/// set to the given values. All other fields carry neutral/zero values
/// so tests can focus on the synthesize surface without constructing a
/// full haystack result.
private func makeMiniResult(
    synthesizePayloadText: String? = nil,
    synthesizeJudgeAnswer: String? = nil,
    synthesizeJudgeCorrect: Bool? = nil,
    synthesizeJudgeTokens: Int? = nil
) -> LMEQuestionResult {
    LMEQuestionResult(
        questionID: "q-0",
        questionType: "single_session_user",
        queryLatencySeconds: nil,
        retrievedUUIDs: [],
        manifest: [],
        answerSessionIDs: [],
        guardHealthy: true,
        guardDiagnostic: nil,
        guardSamplingMode: .oncePerLeg,
        turnsIngested: 0,
        writeMeanLatencySeconds: 0,
        exactPayloadText: nil,
        densePayloadText: nil,
        denseQueryLatencySeconds: nil,
        exactJudgeAnswer: nil,
        exactJudgeCorrect: nil,
        exactGoldReachable: nil,
        exactJudgeTokens: nil,
        denseJudgeTokens: nil,
        previewJudgeAnswer: nil,
        previewJudgeCorrect: nil,
        previewJudgeTokens: nil,
        denseJudgeAnswer: nil,
        denseJudgeCorrect: nil,
        cacheHit: nil,
        drainLaneObserved: nil,
        synthesizePayloadText: synthesizePayloadText,
        synthesizeJudgeAnswer: synthesizeJudgeAnswer,
        synthesizeJudgeCorrect: synthesizeJudgeCorrect,
        synthesizeJudgeTokens: synthesizeJudgeTokens,
        settledRetrievedUUIDs: nil,
        settledQueryLatencySeconds: nil,
        settledDrainLaneObserved: nil)
}
