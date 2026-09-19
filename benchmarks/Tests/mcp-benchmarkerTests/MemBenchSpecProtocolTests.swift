// MemBenchSpecProtocolTests.swift — Unit and conformance tests for MemBenchSpecProtocol.swift.
//
// Two kinds of tests:
//   1. Inline unit tests: exercise every function directly with known inputs and
//      expected outputs. These match the vectors in protocol_vectors.json.
//   2. Conformance vector tests: load conformance/membench-spec/protocol_vectors.json
//      and verify every case against the Swift implementation. Both ports (Swift + Rust)
//      must reproduce identical outputs — that is the conformance contract.
//
// § references point to MEMBENCH_OFFICIAL_PROTOCOL.md section numbers.

import Testing
import Foundation
@testable import mcp_benchmarker

// MARK: - Path helper

/// Resolves `benchmarks/conformance/membench-spec/protocol_vectors.json` from
/// this test file's compile-time path.
///
///   .../Tests/mcp-benchmarkerTests/MemBenchSpecProtocolTests.swift
///     → mcp-benchmarkerTests/     (1st deletingLastPathComponent)
///     → Tests/                    (2nd)
///     → benchmarks/    (3rd = package root)
///     → benchmarks/conformance/membench-spec/protocol_vectors.json
private func protocolVectorsURL(file: String = #filePath) -> URL {
    URL(fileURLWithPath: file)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("conformance")
        .appendingPathComponent("membench-spec")
        .appendingPathComponent("protocol_vectors.json")
}

private func loadProtocolVectors(file: String = #filePath) throws -> [String: Any] {
    let url = protocolVectorsURL(file: file)
    let data = try Data(contentsOf: url)
    let obj = try JSONSerialization.jsonObject(with: data)
    guard let dict = obj as? [String: Any] else {
        throw NSError(domain: "ProtocolVectors", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Expected top-level object in protocol_vectors.json"])
    }
    return dict
}

// MARK: - INITIAL_INSTRUACTION (§2)

@Suite("MemBenchSpecProtocol: INITIAL_INSTRUACTION constant")
struct InitialInstruactionTests {

    @Test("§2: constant name typo and value are official")
    func constantMatchesSpec() {
        #expect(
            INITIAL_INSTRUACTION ==
            "Please help me record the following information. If there are any questions within the information, please help me answer them."
        )
    }

    @Test("§2: INITIAL_INSTRUACTION vector from protocol_vectors.json")
    func vectorMatch() throws {
        let json = try loadProtocolVectors()
        let block = try #require(json["initial_instruaction"] as? [String: Any])
        let expected = try #require(block["expected"] as? String)
        #expect(INITIAL_INSTRUACTION == expected)
    }
}

// MARK: - storageLine string form (§2)

@Suite("MemBenchSpecProtocol: storageLine string form")
struct StorageLineStringTests {

    @Test("§2 string form: step 1 hello world")
    func step1HelloWorld() {
        #expect(storageLine(step: 1, message: "hello world") == "1[|]hello world")
    }

    @Test("§2 string form: step 42 with phrase")
    func step42Phrase() {
        #expect(storageLine(step: 42, message: "Please help me record this.") == "42[|]Please help me record this.")
    }

    @Test("§2 string form: step 0 empty message")
    func step0EmptyMessage() {
        // Delimiter still present even for an empty message.
        #expect(storageLine(step: 0, message: "") == "0[|]")
    }

    @Test("§2 string form: conformance vectors from protocol_vectors.json")
    func conformanceVectors() throws {
        let json = try loadProtocolVectors()
        let cases = try #require(json["storage_line_string_cases"] as? [[String: Any]])
        for c in cases {
            let id = c["id"] as? String ?? "(unknown)"
            let step = try #require(c["step"] as? Int)
            let message = try #require(c["message"] as? String)
            let expected = try #require(c["expected"] as? String)
            let got = storageLine(step: step, message: message)
            #expect(got == expected, "id=\(id): got '\(got)', expected '\(expected)'")
        }
    }
}

// MARK: - storageLine dict form (§2)

@Suite("MemBenchSpecProtocol: storageLine dict form")
struct StorageLineDictTests {

    @Test("§2 dict form: basic user/agent exchange")
    func basicExchange() {
        #expect(
            storageLine(step: 3, user: "Hi there", agent: "Hello!") ==
            "3[|]'user': Hi there; 'agent': Hello!"
        )
    }

    @Test("§2 dict form: step 5 with longer messages")
    func step5LongerMessages() {
        #expect(
            storageLine(step: 5, user: "Good morning", agent: "Good morning to you too!") ==
            "5[|]'user': Good morning; 'agent': Good morning to you too!"
        )
    }

    @Test("§2 dict form: conformance vectors from protocol_vectors.json")
    func conformanceVectors() throws {
        let json = try loadProtocolVectors()
        let cases = try #require(json["storage_line_dict_cases"] as? [[String: Any]])
        for c in cases {
            let id = c["id"] as? String ?? "(unknown)"
            let step = try #require(c["step"] as? Int)
            let user = try #require(c["user"] as? String)
            let agent = try #require(c["agent"] as? String)
            let expected = try #require(c["expected"] as? String)
            let got = storageLine(step: step, user: user, agent: agent)
            #expect(got == expected, "id=\(id): got '\(got)', expected '\(expected)'")
        }
    }
}

// MARK: - stepID(fromStorageLine:) (§4)

@Suite("MemBenchSpecProtocol: stepID parse")
struct StepIDParseTests {

    @Test("§4: string-form line step 1")
    func stringFormStep1() throws {
        #expect(try stepID(fromStorageLine: "1[|]hello world") == 1)
    }

    @Test("§4: large step number")
    func largeStepNumber() throws {
        #expect(try stepID(fromStorageLine: "42[|]some message") == 42)
    }

    @Test("§4: step 0")
    func step0() throws {
        #expect(try stepID(fromStorageLine: "0[|]") == 0)
    }

    @Test("§4: dict-form line — parser reads prefix only")
    func dictFormLine() throws {
        #expect(try stepID(fromStorageLine: "5[|]'user': Hi; 'agent': Bye") == 5)
    }

    @Test("§4: missing delimiter throws missingDelimiter")
    func missingDelimiter() {
        #expect(throws: StorageLineParseError.missingDelimiter) {
            try stepID(fromStorageLine: "malformed line")
        }
    }

    @Test("§4: non-integer prefix throws invalidStepID")
    func invalidPrefix() {
        #expect(throws: StorageLineParseError.invalidStepID) {
            try stepID(fromStorageLine: "abc[|]message")
        }
    }

    @Test("§4: float prefix throws invalidStepID")
    func floatPrefix() {
        #expect(throws: StorageLineParseError.invalidStepID) {
            try stepID(fromStorageLine: "3.5[|]message")
        }
    }

    @Test("§4: empty string throws missingDelimiter")
    func emptyString() {
        #expect(throws: StorageLineParseError.missingDelimiter) {
            try stepID(fromStorageLine: "")
        }
    }

    @Test("§4: conformance vectors from protocol_vectors.json")
    func conformanceVectors() throws {
        let json = try loadProtocolVectors()
        let cases = try #require(json["step_id_parse_cases"] as? [[String: Any]])
        for c in cases {
            let id = c["id"] as? String ?? "(unknown)"
            let input = try #require(c["input"] as? String)
            if let expectedID = c["expected_step_id"] as? Int {
                let got = try stepID(fromStorageLine: input)
                #expect(got == expectedID, "id=\(id): got \(got), expected \(expectedID)")
            } else {
                let errorKey = c["expected_error"] as? String ?? ""
                #expect(throws: (any Error).self, "id=\(id): expected throw for '\(errorKey)'") {
                    try stepID(fromStorageLine: input)
                }
            }
        }
    }
}

// MARK: - recallQuery (§3–4)

@Suite("MemBenchSpecProtocol: recallQuery")
struct RecallQueryTests {

    @Test("§3–4: basic recall query format")
    func basicFormat() {
        #expect(
            recallQuery(question: "Where did the user go on vacation?", time: "2024-01-15 10:00") ==
            "Where did the user go on vacation? (2024-01-15 10:00)"
        )
    }

    @Test("§3–4: natural language time string")
    func naturalLanguageTime() {
        #expect(
            recallQuery(question: "What did Alice say?", time: "last Tuesday") ==
            "What did Alice say? (last Tuesday)"
        )
    }

    @Test("§3–4: conformance vectors from protocol_vectors.json")
    func conformanceVectors() throws {
        let json = try loadProtocolVectors()
        let cases = try #require(json["recall_query_cases"] as? [[String: Any]])
        for c in cases {
            let id = c["id"] as? String ?? "(unknown)"
            let question = try #require(c["question"] as? String)
            let time = try #require(c["time"] as? String)
            let expected = try #require(c["expected"] as? String)
            let got = recallQuery(question: question, time: time)
            #expect(got == expected, "id=\(id): got '\(got)', expected '\(expected)'")
        }
    }
}

// MARK: - answerPrompt (§3)

@Suite("MemBenchSpecProtocol: answerPrompt")
struct AnswerPromptTests {

    private func parisChoices() -> [String: String] {
        ["A": "Paris", "B": "London", "C": "Berlin", "D": "Tokyo"]
    }

    private func hikingChoices() -> [String: String] {
        ["A": "Swimming", "B": "Hiking", "C": "Cycling", "D": "Running"]
    }

    @Test("§3 FirstAgent: official typo 'your'conversation' in first line")
    func firstAgentOfficialTypo() {
        let prompt = answerPrompt(
            perspective: .firstAgent,
            memory: "The user went to Paris.",
            question: "Where did the user go?",
            time: "2024-01-15",
            choices: parisChoices()
        )
        #expect(prompt.hasPrefix(
            "Please answer the following question based on past memories of your'conversation with the user."
        ), "FirstAgent prompt must contain official typo 'your'conversation'")
    }

    @Test("§3 ThirdAgent: third-person framing in first line")
    func thirdAgentFraming() {
        let prompt = answerPrompt(
            perspective: .thirdAgent,
            memory: "Alice mentioned she loves hiking.",
            question: "What does Alice love?",
            time: "2024-02-20",
            choices: hikingChoices()
        )
        #expect(prompt.hasPrefix(
            "Please answer the following question based on past memories of the user's messages."
        ), "ThirdAgent prompt must use third-person framing")
    }

    @Test("§3 FirstAgent: full byte-exact render")
    func firstAgentFullRender() {
        let prompt = answerPrompt(
            perspective: .firstAgent,
            memory: "The user went to Paris.",
            question: "Where did the user go?",
            time: "2024-01-15",
            choices: parisChoices()
        )
        let expected = """
        Please answer the following question based on past memories of your'conversation with the user.
        Past memory: The user went to Paris.
        Question: (current time is 2024-01-15) Where did the user go?
        Choices:
        A. Paris
        B. London
        C. Berlin
        D. Tokyo
        Please output the correct option for the question, only one corresponding letter, without any other messages.
        Example: D
        """
        #expect(prompt == expected)
    }

    @Test("§3 ThirdAgent: full byte-exact render")
    func thirdAgentFullRender() {
        let prompt = answerPrompt(
            perspective: .thirdAgent,
            memory: "Alice mentioned she loves hiking.",
            question: "What does Alice love?",
            time: "2024-02-20",
            choices: hikingChoices()
        )
        let expected = """
        Please answer the following question based on past memories of the user's messages.
        Past memory: Alice mentioned she loves hiking.
        Question: (current time is 2024-02-20) What does Alice love?
        Choices:
        A. Swimming
        B. Hiking
        C. Cycling
        D. Running
        Please output the correct option for the question, only one corresponding letter, without any other messages.
        Example: D
        """
        #expect(prompt == expected)
    }

    @Test("§3: no trailing newline in either template")
    func noTrailingNewline() {
        let first = answerPrompt(perspective: .firstAgent, memory: "m", question: "q", time: "t", choices: [:])
        let third = answerPrompt(perspective: .thirdAgent, memory: "m", question: "q", time: "t", choices: [:])
        #expect(!first.hasSuffix("\n"), "FirstAgent prompt must not end with trailing newline")
        #expect(!third.hasSuffix("\n"), "ThirdAgent prompt must not end with trailing newline")
    }

    @Test("§3: prompt contains exactly 9 newlines (10 lines)")
    func promptLineCount() {
        let prompt = answerPrompt(
            perspective: .firstAgent,
            memory: "m",
            question: "q",
            time: "t",
            choices: ["A": "a", "B": "b", "C": "c", "D": "d"]
        )
        // 10 lines joined by 9 "\n" characters.
        let newlineCount = prompt.filter { $0 == "\n" }.count
        #expect(newlineCount == 9, "§3 template has 10 lines, so 9 newlines; got \(newlineCount)")
    }

    @Test("§3: conformance vectors from protocol_vectors.json")
    func conformanceVectors() throws {
        let json = try loadProtocolVectors()
        let cases = try #require(json["answer_prompt_cases"] as? [[String: Any]])
        for c in cases {
            let id = c["id"] as? String ?? "(unknown)"
            let perspStr = try #require(c["perspective"] as? String)
            let perspective: MemBenchPerspective = perspStr == "FirstAgent" ? .firstAgent : .thirdAgent
            let memory = try #require(c["memory"] as? String)
            let question = try #require(c["question"] as? String)
            let time = try #require(c["time"] as? String)
            let choicesRaw = try #require(c["choices"] as? [String: String])
            let expected = try #require(c["expected"] as? String)
            let got = answerPrompt(
                perspective: perspective, memory: memory,
                question: question, time: time, choices: choicesRaw
            )
            #expect(got == expected, "id=\(id):\ngot:      '\(got)'\nexpected: '\(expected)'")
        }
    }
}

// MARK: - MemBenchAnswerConstraint (§3)

@Suite("MemBenchSpecProtocol: MemBenchAnswerConstraint")
struct AnswerConstraintTests {

    @Test("§3: jsonSchema is a valid JSON object string")
    func jsonSchemaIsValidJSON() throws {
        let data = try #require(MemBenchAnswerConstraint.jsonSchema.data(using: .utf8))
        let obj = try JSONSerialization.jsonObject(with: data)
        #expect(obj is [String: Any])
    }

    @Test("§3 primary path: JSON object with 'choice' key → A")
    func primaryPathA() {
        #expect(MemBenchAnswerConstraint.parseAnswerChoice(from: #"{"choice": "A"}"#) == "A")
    }

    @Test("§3 primary path: JSON object with 'choice' key → D")
    func primaryPathD() {
        #expect(MemBenchAnswerConstraint.parseAnswerChoice(from: #"{"choice": "D"}"#) == "D")
    }

    @Test("§3 fallback: bare letter B → B")
    func fallbackBareLetterB() {
        #expect(MemBenchAnswerConstraint.parseAnswerChoice(from: "B") == "B")
    }

    @Test("§3 fallback: letter with trailing space → C")
    func fallbackWithTrailingSpace() {
        #expect(MemBenchAnswerConstraint.parseAnswerChoice(from: "C ") == "C")
    }

    @Test("§3 fallback: letter followed by newline → A")
    func fallbackWithNewline() {
        #expect(MemBenchAnswerConstraint.parseAnswerChoice(from: "A\n") == "A")
    }

    @Test("§3: letter 'E' not in enum → nil")
    func invalidLetterE() {
        #expect(MemBenchAnswerConstraint.parseAnswerChoice(from: #"{"choice": "E"}"#) == nil)
    }

    @Test("§3: garbage input → nil")
    func garbageInput() {
        #expect(MemBenchAnswerConstraint.parseAnswerChoice(from: "invalid json and not a letter") == nil)
    }

    @Test("§3: empty input → nil")
    func emptyInput() {
        #expect(MemBenchAnswerConstraint.parseAnswerChoice(from: "") == nil)
    }

    @Test("§3: parse_answer_choice conformance vectors from protocol_vectors.json")
    func conformanceVectors() throws {
        let json = try loadProtocolVectors()
        let cases = try #require(json["parse_answer_choice_cases"] as? [[String: Any]])
        for c in cases {
            let id = c["id"] as? String ?? "(unknown)"
            let input = try #require(c["input"] as? String)
            let expected = c["expected"] as? String  // nil means we expect nil result
            let got = MemBenchAnswerConstraint.parseAnswerChoice(from: input)
            #expect(got == expected, "id=\(id): got \(got.map { "'\($0)'" } ?? "nil"), expected \(expected.map { "'\($0)'" } ?? "nil")")
        }
    }
}

// MARK: - memBenchCountTokens seam (§6 / §7 row 6)

@Suite("MemBenchSpecProtocol: memBenchCountTokens seam")
struct TokenCounterSeamTests {

    /// The seam fails loud when the external artifact is absent. The Makefile
    /// exports this path from BENCH_WORK_ROOT for builds and test runs.
    private static let fixturePresent: Bool = {
        guard let path = ProcessInfo.processInfo.environment["MOOT_BENCH_CL100K"] else {
            return false
        }
        return FileManager.default.fileExists(atPath: path)
    }()

    // These two tests require the cl100k_base.tiktoken artifact pointed to by
    // MOOT_BENCH_CL100K. On a clean checkout the variable is unset and the
    // fixture is absent, so the tests are disabled (skipped, not failed) via
    // the .enabled(if:) trait. Run scripts/fetch-cl100k.sh to download the
    // artifact; the Makefile sets MOOT_BENCH_CL100K for instrumented runs.
    @Test("§7 row 6 resolved: seam counts with cl100k_base (golden-pin values)",
          .enabled(if: TokenCounterSeamTests.fixturePresent,
                   "cl100k fixture absent — run scripts/fetch-cl100k.sh"))
    func countsWithCl100k() throws {
        // Values pinned by the cl100k conformance vectors (tiktoken 0.14.0 oracle):
        // "Hello world" → [9906, 1917]; "The quick brown fox" → 4 tokens.
        #expect(memBenchCountTokens("Hello world") == 2)
        #expect(memBenchCountTokens("The quick brown fox") == 4)
    }

    @Test("§7 row 6: empty string → 0",
          .enabled(if: TokenCounterSeamTests.fixturePresent,
                   "cl100k fixture absent — run scripts/fetch-cl100k.sh"))
    func emptyString() throws {
        #expect(memBenchCountTokens("") == 0)
    }
}
