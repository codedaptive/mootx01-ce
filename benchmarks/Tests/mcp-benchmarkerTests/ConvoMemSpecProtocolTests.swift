import Testing
import Foundation
@testable import mcp_benchmarker

// ConvoMemSpecProtocolTests.swift — vector-driven conformance tests for ConvoMemSpecProtocol.swift.
//
// Pins the Swift leg against conformance/convomem-spec/protocol_vectors.json.
// Both ports (Swift + Rust) must produce byte-identical output on every vector.
//
// Spec references: LMEB_CONVOMEM_OFFICIAL_PROTOCOL.md §B1–§B4.
// Suites:
//   ConvoMemSpecContextTests          — §B1 buildConversationContext
//   ConvoMemSpecModelAnswerPromptTests — §B1 modelAnswerPrompt
//   ConvoMemSpecMemoryBasedPromptTests — §B1 memoryBasedPrompt
//   ConvoMemSpecCriteriaTests          — §B1 judgeEvaluationCriteria
//   ConvoMemSpecJudgePromptTests       — §B2 template dispatch
//   ConvoMemSpecVerdictParsingTests    — §B3 verdict parsing
//   ConvoMemSpecAggregationTests       — §B4 aggregation
//   ConvoMemSpecGoldenPinTests         — byte-exact spot checks

// MARK: - Fixture path helper

/// Resolves `benchmarks/conformance/convomem-spec/<filename>` from this test file.
///
/// Path walk:
///   .../Tests/mcp-benchmarkerTests/ConvoMemSpecProtocolTests.swift
///   → mcp-benchmarkerTests/  (1st deletingLastPathComponent)
///   → Tests/                 (2nd)
///   → benchmarks/             (3rd = package root)
///   → benchmarks/conformance/convomem-spec/<filename>
private func convoMemSpecConformancePath(_ filename: String, file: String = #filePath) -> URL {
    URL(fileURLWithPath: file)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("conformance")
        .appendingPathComponent("convomem-spec")
        .appendingPathComponent(filename)
}

/// Loads and deserialises the protocol conformance JSON.
private func loadConvoMemSpecVectors(file: String = #filePath) throws -> [String: Any] {
    let url  = convoMemSpecConformancePath("protocol_vectors.json", file: file)
    let data = try Data(contentsOf: url)
    let obj  = try JSONSerialization.jsonObject(with: data)
    guard let dict = obj as? [String: Any] else {
        throw NSError(domain: "ConvoMemSpecVectors", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Expected top-level JSON object"])
    }
    return dict
}

// MARK: - JSON helpers

/// Decodes a `conversations` JSON array into `[ConvoMemConversation]`.
private func decodeConversations(_ arr: [[String: Any]]) -> [ConvoMemConversation] {
    arr.map { conv in
        let msgs = (conv["messages"] as? [[String: Any]] ?? []).map { msg in
            ConvoMemMessage(
                speaker: msg["speaker"] as? String ?? "",
                text:    msg["text"]    as? String ?? ""
            )
        }
        return ConvoMemConversation(messages: msgs)
    }
}

/// Decodes an `evidence_messages` JSON array into `[ConvoMemEvidenceMessage]`.
private func decodeEvidenceMessages(_ arr: [[String: Any]]) -> [ConvoMemEvidenceMessage] {
    arr.compactMap { ConvoMemEvidenceMessage(text: $0["text"] as? String ?? "") }
}

/// Maps the `outcome` string from the JSON to `ConvoMemVerdictOutcome`.
private func outcomeFromString(_ s: String) -> ConvoMemVerdictOutcome {
    switch s {
    case "correct":   return .correct
    case "incorrect": return .incorrect
    default:          return .invalid
    }
}

/// Returns a human-readable label for a verdict outcome (for assertion messages).
private func outcomeLabel(_ o: ConvoMemVerdictOutcome) -> String {
    switch o {
    case .correct:   return "correct"
    case .incorrect: return "incorrect"
    case .invalid:   return "invalid"
    }
}

// MARK: - §B1 buildConversationContext

@Suite("ConvoMemSpec buildConversationContext — §B1 conformance vectors")
struct ConvoMemSpecContextTests {

    /// Drives every `build_conversation_context` vector.
    ///
    /// §B1: conversations are numbered 1-based; turns joined by "\n";
    /// conversations joined by "\n\n".
    @Test("All ctx_* vectors: buildConversationContext produces expected string")
    func allContextVectors() throws {
        let json  = try loadConvoMemSpecVectors()
        let cases = try #require(json["build_conversation_context"] as? [[String: Any]])

        for c in cases {
            let id    = c["id"] as? String ?? "(unknown)"
            let input = try #require(c["input"] as? [String: Any],
                                     "case \(id): missing 'input'")
            let convArr  = input["conversations"] as? [[String: Any]] ?? []
            let expected = try #require(c["expected"] as? String,
                                        "case \(id): missing 'expected'")

            let conversations = decodeConversations(convArr)
            let got           = convoMemBuildConversationContext(conversations)

            #expect(got == expected,
                    "case \(id): got '\(got)' expected '\(expected)'")
        }
    }
}

// MARK: - §B1 modelAnswerPrompt

@Suite("ConvoMemSpec modelAnswerPrompt — §B1 conformance vectors")
struct ConvoMemSpecModelAnswerPromptTests {

    /// Drives every `model_answer_prompt` vector.
    ///
    /// §B1: full-context prompt embeds the conversation context, then
    /// "Question: …\n\nAnswer:" with no trailing newline.
    @Test("All map_* vectors: modelAnswerPrompt byte-exact against expected")
    func allModelAnswerPromptVectors() throws {
        let json  = try loadConvoMemSpecVectors()
        let cases = try #require(json["model_answer_prompt"] as? [[String: Any]])

        for c in cases {
            let id    = c["id"] as? String ?? "(unknown)"
            let input = try #require(c["input"] as? [String: Any],
                                     "case \(id): missing 'input'")
            let convs    = decodeConversations(input["conversations"] as? [[String: Any]] ?? [])
            let question = input["question"] as? String ?? ""
            let expected = try #require(c["expected"] as? String,
                                        "case \(id): missing 'expected'")

            let got = convoMemModelAnswerPrompt(conversations: convs, question: question)
            #expect(got == expected, "case \(id): modelAnswerPrompt mismatch")
        }
    }
}

// MARK: - §B1 memoryBasedPrompt

@Suite("ConvoMemSpec memoryBasedPrompt — §B1 conformance vectors")
struct ConvoMemSpecMemoryBasedPromptTests {

    /// Drives every `memory_based_prompt` vector through structural checks.
    ///
    /// §B1: memory-based prompt embeds the criteria block, numbered memories (1-based),
    /// ends with "Answer:", no trailing newline.
    @Test("All mbp_* vectors: memoryBasedPrompt satisfies structural checks")
    func allMemoryBasedPromptVectors() throws {
        let json  = try loadConvoMemSpecVectors()
        let cases = try #require(json["memory_based_prompt"] as? [[String: Any]])

        for c in cases {
            let id    = c["id"] as? String ?? "(unknown)"
            let input = try #require(c["input"] as? [String: Any],
                                     "case \(id): missing 'input'")
            let question = input["question"] as? String ?? ""
            let memories = input["memories"] as? [String] ?? []

            let got = convoMemMemoryBasedPrompt(question: question, memories: memories)

            // expected_suffix: the output must end with this literal suffix.
            if let suffix = c["expected_suffix"] as? String {
                #expect(got.hasSuffix(suffix),
                        "case \(id): output must end with expected_suffix")
            }

            // expected_memories_block: the numbered memory list must appear verbatim.
            if let memBlock = c["expected_memories_block"] as? String {
                #expect(got.contains(memBlock),
                        "case \(id): expected_memories_block not found in output")
            }

            // expected_ends_with: softer suffix check (reused across cases).
            if let ends = c["expected_ends_with"] as? String {
                #expect(got.hasSuffix(ends),
                        "case \(id): output must end with '\(ends)'")
            }

            // No trailing newline — §B1 matches Scala source which closes with 'Answer:'.
            if c["expected_no_trailing_newline"] as? Bool == true {
                #expect(!got.hasSuffix("\n"),
                        "case \(id): output must not end with newline")
            }
        }
    }
}

// MARK: - §B1 judgeEvaluationCriteria

@Suite("ConvoMemSpec judgeEvaluationCriteria — §B1 criteria checks")
struct ConvoMemSpecCriteriaTests {

    /// Verifies the criteria block has verbatim trailing space on items 2 and 5 (§B1),
    /// starts with "When answering,", ends with "what you don't know.", no trailing newline.
    ///
    /// The trailing space is byte-verbatim from cm_MemoryPromptUtils.scala lines 22 and 34.
    @Test("criteria_trailing_spaces: items 2 and 5 carry trailing space (verbatim Scala)")
    func criteriaTrailingSpaces() throws {
        let json   = try loadConvoMemSpecVectors()
        let cases  = try #require(json["judge_evaluation_criteria"] as? [[String: Any]])
        let c      = try #require(cases.first, "Expected at least one criteria case")
        let checks = c["checks"] as? [[String: Any]] ?? []

        let result = convoMemJudgeEvaluationCriteria()

        for check in checks {
            if let sub = check["contains"] as? String {
                #expect(result.contains(sub),
                        "criteria must contain '\(sub)' (verbatim trailing space)")
            }
            if let pre = check["starts_with"] as? String {
                #expect(result.hasPrefix(pre),
                        "criteria must start with '\(pre)'")
            }
            if let suf = check["ends_with"] as? String {
                #expect(result.hasSuffix(suf),
                        "criteria must end with '\(suf)'")
            }
            if check["no_trailing_newline"] as? Bool == true {
                #expect(!result.hasSuffix("\n"),
                        "criteria must not end with newline")
            }
        }
    }
}

// MARK: - §B2 judge prompt dispatch

@Suite("ConvoMemSpec judgePrompts — §B2 template dispatch vectors")
struct ConvoMemSpecJudgePromptTests {

    /// Builds the judge prompt for a given function name and input dictionary.
    ///
    /// Maps the JSON "function" string to the matching Swift builder.
    private func buildPrompt(fn: String, input: [String: Any]) -> String? {
        let question    = input["question"]       as? String ?? ""
        let correctAns  = input["correct_answer"] as? String ?? ""
        let modelAnswer = input["model_answer"]   as? String ?? ""

        switch fn {
        case "default_factual":
            // §B2: assistant_facts_evidence → DefaultAnsweringEvaluation.
            return convoMemDefaultFactualJudgePrompt(
                question:      question,
                correctAnswer: correctAns,
                modelAnswer:   modelAnswer
            )
        case "rubric_based":
            // §B2: preference + implicit_connection → RubricBasedAnsweringEvaluation.
            // The JSON vector uses "rubric" when present; otherwise falls back to correct_answer.
            let rubric = input["rubric"] as? String ?? correctAns
            return convoMemRubricBasedJudgePrompt(
                question:    question,
                rubric:      rubric,
                modelAnswer: modelAnswer
            )
        case "temporal":
            // §B2: changing_evidence → TemporalAnsweringEvaluation.
            return convoMemTemporalJudgePrompt(
                question:      question,
                correctAnswer: correctAns,
                modelAnswer:   modelAnswer
            )
        case "user_facts":
            // §B2: user_evidence → UserFactsAnsweringEvaluation(evidenceCount).
            let evidenceCount = input["evidence_count"]   as? Int ?? 1
            let evidenceMsgs  = decodeEvidenceMessages(
                input["evidence_messages"] as? [[String: Any]] ?? []
            )
            return convoMemUserFactsJudgePrompt(
                question:         question,
                correctAnswer:    correctAns,
                modelAnswer:      modelAnswer,
                evidenceMessages: evidenceMsgs,
                evidenceCount:    evidenceCount
            )
        case "abstention":
            // §B2: abstention_evidence → AbstentionAnsweringEvaluation (correctAnswer not embedded).
            return convoMemAbstentionJudgePrompt(
                question:    question,
                modelAnswer: modelAnswer
            )
        default:
            return nil
        }
    }

    /// Drives every `judge_prompts` vector through the matching builder.
    @Test("All judge_* vectors: template dispatch and structural checks")
    func allJudgePromptVectors() throws {
        let json  = try loadConvoMemSpecVectors()
        let cases = try #require(json["judge_prompts"] as? [[String: Any]])

        for c in cases {
            let id     = c["id"]       as? String ?? "(unknown)"
            let fn     = try #require(c["function"] as? String,
                                      "case \(id): missing 'function'")
            let input  = try #require(c["input"]    as? [String: Any],
                                      "case \(id): missing 'input'")
            let checks = c["checks"]   as? [[String: Any]] ?? []

            let result = try #require(buildPrompt(fn: fn, input: input),
                                      "case \(id): unknown function '\(fn)'")

            for check in checks {
                if let sub = check["contains"] as? String {
                    #expect(result.contains(sub),
                            "case \(id) [\(fn)]: must contain '\(sub)'")
                }
                if let suf = check["ends_with"] as? String {
                    #expect(result.hasSuffix(suf),
                            "case \(id) [\(fn)]: must end with '\(suf)'")
                }
                if let notSub = check["not_contains"] as? String {
                    #expect(!result.contains(notSub),
                            "case \(id) [\(fn)]: must NOT contain '\(notSub)'")
                }
                if check["no_trailing_newline"] as? Bool == true {
                    #expect(!result.hasSuffix("\n"),
                            "case \(id) [\(fn)]: must not end with newline")
                }
            }
        }
    }
}

// MARK: - §B3 verdict parsing

@Suite("ConvoMemSpec verdictParsing — §B3 conformance vectors")
struct ConvoMemSpecVerdictParsingTests {

    /// Drives every `verdict_parsing` vector through `convoMemVerdict`.
    ///
    /// §B3: trim+lowercase → contains("right") / contains("wrong").
    /// Both present → ambiguous → .incorrect (NOT .invalid).
    /// Neither → .invalid (retry signal).
    @Test("All verdict_parsing vectors: §B3 outcome matches expected string")
    func allVerdictParsingVectors() throws {
        let json  = try loadConvoMemSpecVectors()
        let cases = try #require(json["verdict_parsing"] as? [[String: Any]])

        for c in cases {
            let id       = c["id"]       as? String ?? "(unknown)"
            let input    = try #require(c["input"]    as? String,
                                        "case \(id): missing 'input'")
            let expected = try #require(c["expected"] as? String,
                                        "case \(id): missing 'expected'")

            let got = convoMemVerdict(input)
            #expect(outcomeLabel(got) == expected,
                    "case \(id): got '\(outcomeLabel(got))' expected '\(expected)'")
        }
    }

    // §B3 golden pin: "RIGHT and WRONG" → ambiguous → .incorrect, NOT .invalid.
    //
    // This is the critical §B3 rule: when both "right" and "wrong" are present the
    // verdict is false (incorrect), not a retry signal (invalid). The distinction matters:
    // invalid triggers the bounded-retry loop; incorrect scores the question as wrong.
    @Test("§B3 golden pin: ambiguous both-present → incorrect, not invalid")
    func goldenPinAmbiguousBothPresent() {
        let outcome = convoMemVerdict("RIGHT and WRONG")
        #expect(outcome == .incorrect,
                "§B3: both 'right' and 'wrong' present → ambiguous → .incorrect")
        #expect(outcome != .invalid,
                "§B3: ambiguous must NOT be .invalid — invalid triggers retry, not a score")
    }
}

// MARK: - §B4 aggregation

@Suite("ConvoMemSpec aggregation — §B4 conformance vectors")
struct ConvoMemSpecAggregationTests {

    /// Drives every `aggregation` vector through `convoMemAggregate`.
    ///
    /// §B4: accuracy per evidence type, per evidence count, overall.
    /// .invalid rows excluded from accuracy denominator.
    @Test("All aggregation vectors: §B4 accuracy and counts match expected")
    func allAggregationVectors() throws {
        let json  = try loadConvoMemSpecVectors()
        let cases = try #require(json["aggregation"] as? [[String: Any]])

        for c in cases {
            let id       = c["id"]       as? String ?? "(unknown)"
            let input    = try #require(c["input"]    as? [String: Any],
                                        "case \(id): missing 'input'")
            let expected = try #require(c["expected"] as? [String: Any],
                                        "case \(id): missing 'expected'")
            let rowsJSON = input["rows"] as? [[String: Any]] ?? []

            let rows: [ConvoMemVerdictRow] = rowsJSON.map { row in
                ConvoMemVerdictRow(
                    evidenceType:  row["evidence_type"]  as? String ?? "",
                    evidenceCount: row["evidence_count"] as? Int    ?? 1,
                    outcome:       outcomeFromString(row["outcome"] as? String ?? "invalid")
                )
            }

            let result = convoMemAggregate(rows)

            if let wantAcc = expected["overall_accuracy"] as? Double {
                // Tolerance 1e-4 — §B4 rounds to 4 decimal places.
                #expect(abs(result.overallAccuracy - wantAcc) < 1e-4,
                        "case \(id): overall_accuracy \(result.overallAccuracy) ≠ \(wantAcc)")
            }
            if let wantCorrect = expected["overall_correct_count"] as? Int {
                #expect(result.overallCorrectCount == wantCorrect,
                        "case \(id): overall_correct_count mismatch")
            }
            if let wantScored = expected["overall_scored_count"] as? Int {
                #expect(result.overallScoredCount == wantScored,
                        "case \(id): overall_scored_count mismatch")
            }
            if let wantUnscored = expected["overall_unscored_count"] as? Int {
                #expect(result.overallUnscoredCount == wantUnscored,
                        "case \(id): overall_unscored_count mismatch")
            }
        }
    }

    // §B4 golden pin: agg_basic — 4-decimal rounding on 2/3 = 0.6667.
    //
    // §B4 counts alongside means; invalid rows excluded from denominator, not scored wrong.
    @Test("§B4 golden pin: agg_basic — 2 correct / 3 scored → 0.6667, 1 unscored")
    func goldenPinAggBasic() {
        let rows: [ConvoMemVerdictRow] = [
            ConvoMemVerdictRow(evidenceType: "user_evidence",     evidenceCount: 1, outcome: .correct),
            ConvoMemVerdictRow(evidenceType: "user_evidence",     evidenceCount: 1, outcome: .incorrect),
            ConvoMemVerdictRow(evidenceType: "changing_evidence", evidenceCount: 2, outcome: .correct),
            ConvoMemVerdictRow(evidenceType: "user_evidence",     evidenceCount: 1, outcome: .invalid),
        ]
        let r = convoMemAggregate(rows)
        // convoMemRound4(2.0/3.0) = round(0.6666... * 10000) / 10000 = 6667 / 10000 = 0.6667
        #expect(r.overallAccuracy      == 0.6667,
                "overall_accuracy must round to 0.6667 (§B4 4-decimal rounding)")
        #expect(r.overallCorrectCount  == 2, "overallCorrectCount")
        #expect(r.overallScoredCount   == 3, "overallScoredCount (invalid excluded)")
        #expect(r.overallUnscoredCount == 1, "overallUnscoredCount")
    }

    // §B4 golden pin: agg_all_invalid — 0.0 accuracy, all rows unscored.
    @Test("§B4 golden pin: agg_all_invalid → accuracy 0.0, scored 0")
    func goldenPinAggAllInvalid() {
        let rows: [ConvoMemVerdictRow] = [
            ConvoMemVerdictRow(evidenceType: "abstention_evidence", evidenceCount: 1, outcome: .invalid),
            ConvoMemVerdictRow(evidenceType: "abstention_evidence", evidenceCount: 1, outcome: .invalid),
        ]
        let r = convoMemAggregate(rows)
        #expect(r.overallAccuracy      == 0.0, "all-invalid accuracy must be 0.0")
        #expect(r.overallScoredCount   == 0,   "all-invalid scored must be 0")
        #expect(r.overallUnscoredCount == 2,   "all-invalid unscored == row count")
    }

    // §B4 golden pin: agg_all_correct — accuracy 1.0, none unscored.
    @Test("§B4 golden pin: agg_all_correct → accuracy 1.0")
    func goldenPinAggAllCorrect() {
        let rows: [ConvoMemVerdictRow] = [
            ConvoMemVerdictRow(evidenceType: "user_evidence", evidenceCount: 1, outcome: .correct),
            ConvoMemVerdictRow(evidenceType: "user_evidence", evidenceCount: 1, outcome: .correct),
        ]
        let r = convoMemAggregate(rows)
        #expect(r.overallAccuracy      == 1.0, "all-correct accuracy must be 1.0")
        #expect(r.overallCorrectCount  == 2,   "overallCorrectCount")
        #expect(r.overallScoredCount   == 2,   "overallScoredCount")
        #expect(r.overallUnscoredCount == 0,   "overallUnscoredCount")
    }
}

// MARK: - Golden pins

@Suite("ConvoMemSpec golden pins — byte-exact spot checks")
struct ConvoMemSpecGoldenPinTests {

    // §B1 golden pin: memoryBasedPrompt with one memory.
    //
    // Verifies: 1-based numbered memory in block, ends with "Answer:", no trailing newline.
    @Test("§B1 golden pin: memoryBasedPrompt one-memory ends with 'Answer:'")
    func goldenPinMemoryBasedPromptOneMemory() {
        let prompt = convoMemMemoryBasedPrompt(
            question: "What is the user's favorite food?",
            memories: ["The user mentioned they love pasta."]
        )
        // 1-based numbering in memories block.
        #expect(prompt.contains("1. The user mentioned they love pasta."),
                "memory block must contain '1. ...' numbered entry")
        // No trailing newline — §B1 matches Scala source 'Answer:"""'.
        #expect(prompt.hasSuffix("Answer:"),
                "memoryBasedPrompt must end with 'Answer:'")
        #expect(!prompt.hasSuffix("\n"),
                "memoryBasedPrompt must not end with newline")
    }

    // §B1 golden pin: memoryBasedPrompt with empty memories.
    //
    // Empty variant embeds "I don't know" fallback instruction, ends with "Answer:".
    @Test("§B1 golden pin: memoryBasedPrompt empty-memories ends with 'Answer:'")
    func goldenPinMemoryBasedPromptEmpty() {
        let prompt = convoMemMemoryBasedPrompt(
            question: "What is the user's favorite food?",
            memories: []
        )
        #expect(prompt.contains("I don't know"),
                "empty-memories prompt must reference 'I don't know' fallback")
        #expect(prompt.hasSuffix("Answer:"),
                "empty-memories prompt must end with 'Answer:'")
        #expect(!prompt.hasSuffix("\n"),
                "empty-memories prompt must not end with newline")
    }

    // §B2 golden pin: default factual template — two-space guideline numbering.
    //
    // §B2 verbatim from cm_DefaultFactualJudgePrompt.scala: "1.  **Core Information is Key**"
    // (two spaces after the period). Any change would break byte-equality with the Rust port.
    @Test("§B2 golden pin: default factual — two-space guideline 1. and 'Answer (RIGHT/WRONG):'")
    func goldenPinDefaultFactualTemplate() {
        let p = convoMemDefaultFactualJudgePrompt(
            question:      "What color is the car?",
            correctAnswer: "Blue",
            modelAnswer:   "The car is blue."
        )
        // Two spaces after "1." — verbatim from the Scala source (not a typo).
        #expect(p.contains("1.  **Core Information is Key**"),
                "default factual must have two spaces after '1.' (verbatim Scala)")
        #expect(p.hasSuffix("Answer (RIGHT/WRONG):"),
                "default factual must end with 'Answer (RIGHT/WRONG):'")
        #expect(!p.hasSuffix("\n"),
                "default factual must not end with newline")
    }

    // §B2 golden pin: userfacts single — trailing space on "**Question Asked:** \n".
    //
    // The trailing space before the newline in "**Question Asked:** \n" is verbatim
    // from cm_UserFactsAnsweringEvaluation.scala and must survive both ports.
    @Test("§B2 golden pin: userfacts single — trailing space on '**Question Asked:** \\n'")
    func goldenPinUserFactsSingleTrailingSpace() {
        let p = convoMemUserFactsJudgePrompt(
            question:         "What does the user eat?",
            correctAnswer:    "Pasta",
            modelAnswer:      "The user eats pasta.",
            evidenceMessages: [ConvoMemEvidenceMessage(text: "User: I eat pasta for dinner every night.")],
            evidenceCount:    1
        )
        // Space before the newline is intentional (verbatim from Scala source).
        #expect(p.contains("**Question Asked:** \n"),
                "userfacts single must contain '**Question Asked:** \\n' (trailing space)")
        // Single-evidence form: "Evidence Message Available to the Model:" (singular).
        #expect(p.contains("**Evidence Message Available to the Model:**"),
                "userfacts single must use singular evidence header")
        #expect(p.hasSuffix("Answer (RIGHT/WRONG):"),
                "userfacts single must end with 'Answer (RIGHT/WRONG):'")
    }

    // §B2 golden pin: userfacts multi — numbered evidence messages, plural header.
    @Test("§B2 golden pin: userfacts multi — numbered messages and plural header")
    func goldenPinUserFactsMultiNumberedMessages() {
        let p = convoMemUserFactsJudgePrompt(
            question:         "What does the user eat?",
            correctAnswer:    "Pasta and sushi",
            modelAnswer:      "The user eats pasta and sushi.",
            evidenceMessages: [
                ConvoMemEvidenceMessage(text: "User: I eat pasta for dinner every night."),
                ConvoMemEvidenceMessage(text: "User: I also love sushi on weekends."),
            ],
            evidenceCount: 2
        )
        // Multi-evidence form: "Evidence Messages Available to the Model:" (plural).
        #expect(p.contains("**Evidence Messages Available to the Model:**"),
                "userfacts multi must use plural evidence header")
        // Messages numbered 1-based.
        #expect(p.contains("Evidence Message 1: User: I eat pasta for dinner every night."),
                "userfacts multi must number message 1")
        #expect(p.contains("Evidence Message 2: User: I also love sushi on weekends."),
                "userfacts multi must number message 2")
        #expect(p.hasSuffix("Answer (RIGHT/WRONG):"),
                "userfacts multi must end with 'Answer (RIGHT/WRONG):'")
    }

    // §B2 golden pin: abstention — "Correct Answer" must not appear.
    //
    // AbstentionAnsweringEvaluation treats abstaining as success and must not embed
    // the ground-truth correct answer (which would defeat the purpose).
    @Test("§B2 golden pin: abstention — omits 'Correct Answer', contains 'Abstention is Success'")
    func goldenPinAbstentionNoCorrectAnswer() {
        let p = convoMemAbstentionJudgePrompt(
            question:    "What is the user's phone number?",
            modelAnswer: "I don't have that information."
        )
        #expect(p.contains("Abstention is Success"),
                "abstention template must reference abstention success")
        #expect(!p.contains("Correct Answer"),
                "abstention template must NOT embed the correct answer")
        #expect(p.hasSuffix("Answer (RIGHT/WRONG):"),
                "abstention template must end with 'Answer (RIGHT/WRONG):'")
    }

    // §B2 golden pin: convoMemJudgePrompt selector — each evidence type routes to the right template.
    //
    // §B2 mapping verbatim from cm_EvaluationUtils.scala:
    //   assistant_facts_evidence → DefaultAnsweringEvaluation
    //   preference_evidence, implicit_connection_evidence → RubricBasedAnsweringEvaluation
    //   changing_evidence → TemporalAnsweringEvaluation
    //   user_evidence → UserFactsAnsweringEvaluation
    //   abstention_evidence → AbstentionAnsweringEvaluation
    @Test("§B2 golden pin: judgePrompt selector routes all five evidence types correctly")
    func goldenPinJudgePromptSelector() {
        let q  = "What does the user prefer?"
        let ca = "Email"
        let ma = "The user prefers email."

        let assistantFacts = convoMemJudgePrompt(
            evidenceType: .assistantFactsEvidence, question: q, correctAnswer: ca, modelAnswer: ma)
        #expect(assistantFacts.contains("Core Information is Key"),
                ".assistantFactsEvidence → default factual")

        let preference = convoMemJudgePrompt(
            evidenceType: .preferenceEvidence, question: q, correctAnswer: ca, modelAnswer: ma)
        #expect(preference.contains("ALL criteria"),
                ".preferenceEvidence → rubric-based")

        let implicit_ = convoMemJudgePrompt(
            evidenceType: .implicitConnectionEvidence, question: q, correctAnswer: ca, modelAnswer: ma)
        #expect(implicit_.contains("ALL criteria"),
                ".implicitConnectionEvidence → rubric-based")

        let changing = convoMemJudgePrompt(
            evidenceType: .changingEvidence, question: q, correctAnswer: ca, modelAnswer: ma)
        #expect(changing.contains("Off-by-one errors"),
                ".changingEvidence → temporal")

        let user = convoMemJudgePrompt(
            evidenceType: .userEvidence, question: q, correctAnswer: ca, modelAnswer: ma)
        #expect(user.contains("Question Asked"),
                ".userEvidence → user-facts")

        let abstention = convoMemJudgePrompt(
            evidenceType: .abstentionEvidence, question: q, correctAnswer: ca, modelAnswer: ma)
        #expect(abstention.contains("Abstention is Success"),
                ".abstentionEvidence → abstention")
    }

    // §B3 golden pin: verdict case sensitivity, whitespace trimming.
    @Test("§B3 golden pin: verdict trim and case-insensitive comparison")
    func goldenPinVerdictTrimAndCase() {
        // §B3 step 1: response.content.trim.toLowerCase before comparison.
        #expect(convoMemVerdict("RIGHT")     == .correct)
        #expect(convoMemVerdict("right")     == .correct)
        #expect(convoMemVerdict("  RIGHT  ") == .correct)
        #expect(convoMemVerdict("WRONG")     == .incorrect)
        #expect(convoMemVerdict("wrong")     == .incorrect)
        // Neither → invalid.
        #expect(convoMemVerdict("")          == .invalid)
        #expect(convoMemVerdict("maybe")     == .invalid)
        // Both → ambiguous → incorrect (NOT invalid).
        #expect(convoMemVerdict("RIGHT and WRONG") == .incorrect)
    }
}
