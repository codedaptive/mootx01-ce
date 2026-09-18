import Testing
import Foundation
@testable import mcp_benchmarker

// DumpJudgeInputsTests — pure unit tests for the dump-judge-inputs JSONL contract
// and the judge-batch offline processing path.
//
// Test C: JSONL format verification — the header and question line schema.
// Test D: judge-batch verdict parsing — 3-line synthetic JSONL produces a
//         verdict file with correct fields.
//
// All tests are pure (no live MCP, no estate, no fixture dataset loading).

// MARK: - Test C: JSONL format contract

@Suite("dump-judge-inputs JSONL format contract")
struct DumpJudgeInputsFormatTests {

    // Verifies that the JSON produced for a header line contains all required fields.
    @Test("header line has required type, benchmark, seed, run_label, arm, judge_hydration_depth")
    func headerLineHasRequiredFields() throws {
        let headerDict: [String: Any] = [
            "type": "header",
            "benchmark": "longmemeval",
            "variant": "s",
            "seed": 42,
            "run_label": "test-run",
            "arm": "both",
            "judge_hydration_depth": 10,
        ]
        let data = try JSONSerialization.data(withJSONObject: headerDict)
        let parsed = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(parsed["type"] as? String == "header")
        #expect(parsed["benchmark"] as? String == "longmemeval")
        #expect(parsed["seed"] != nil)
        #expect(parsed["run_label"] != nil)
        #expect(parsed["arm"] as? String == "both")
        #expect(parsed["judge_hydration_depth"] != nil)
    }

    // Verifies that a question line has all required fields, with null arms handled correctly.
    @Test("question line has required fields; null arms serialize as NSNull")
    func questionLineHasRequiredFields() throws {
        let questionDict: [String: Any] = [
            "type": "question",
            "question_id": "q001",
            "question": "What is the capital?",
            "gold_answer": "Paris",
            "exact_payload": "The capital of France is Paris.",
            "exact_payload_tokens": 8,
            "dense_payload": NSNull(),
            "dense_payload_tokens": NSNull(),
        ]
        let data = try JSONSerialization.data(withJSONObject: questionDict, options: [.sortedKeys])
        let parsed = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(parsed["type"] as? String == "question")
        #expect(parsed["question_id"] as? String == "q001")
        #expect(parsed["gold_answer"] as? String == "Paris")
        #expect(parsed["exact_payload"] as? String != nil)
        #expect(parsed["exact_payload_tokens"] as? Int == 8)
        #expect(parsed["dense_payload"] is NSNull)
        #expect(parsed["dense_payload_tokens"] is NSNull)
    }

    // Verifies arm values match the LMEArm rawValue contract: "exact", "dense", "both".
    @Test("arm field encodes LMEArm raw values correctly")
    func armFieldEncodesLMEArm() {
        #expect(LMEArm.exact.rawValue == "exact")
        #expect(LMEArm.dense.rawValue == "dense")
        #expect(LMEArm.both.rawValue == "both")
    }

    // Verifies that a full synthetic dump file (header + 2 question lines) is
    // parseable as JSONL: each line is valid JSON with the expected type field.
    @Test("synthetic dump file is parseable JSONL with correct type fields")
    func syntheticDumpFileIsParseable() throws {
        let header = """
        {"type":"header","benchmark":"longmemeval","variant":"s","seed":42,"run_label":"test","arm":"both","judge_hydration_depth":10}
        """
        let q1 = """
        {"type":"question","question_id":"q001","question":"Capital?","gold_answer":"Paris","exact_payload":"Paris","exact_payload_tokens":2,"dense_payload":null,"dense_payload_tokens":null}
        """
        let q2 = """
        {"type":"question","question_id":"q002","question":"River?","gold_answer":"Seine","exact_payload":"Seine","exact_payload_tokens":2,"dense_payload":"The Seine","dense_payload_tokens":3}
        """
        let jsonl = [header, q1, q2].joined(separator: "\n") + "\n"

        let lines = jsonl.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 3)

        let parsedHeader = try #require(
            try JSONSerialization.jsonObject(
                with: Data(lines[0].utf8)) as? [String: Any])
        #expect(parsedHeader["type"] as? String == "header")

        for line in lines.dropFirst() {
            let parsed = try #require(
                try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            #expect(parsed["type"] as? String == "question")
            #expect(parsed["question_id"] as? String != nil)
            #expect(parsed["gold_answer"] as? String != nil)
        }
    }
}

// MARK: - Test D: judge-batch verdict parsing

@Suite("judge-batch verdict parsing")
struct JudgeBatchVerdictTests {

    // Writes a 3-line synthetic JSONL (header + 2 questions), calls judgebatchRunBatch
    // with `echo Paris` as the judge command, and verifies the verdict file.
    @Test("3-line synthetic JSONL produces verdict file with correct fields")
    func syntheticJSONLProducesVerdictFile() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DumpJudgeTests-\(Int.random(in: 100_000...999_999))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dumpURL = tempDir.appendingPathComponent("dump.jsonl")

        // Header + 2 questions. q001 has exact only; q002 has exact + dense.
        let header = #"{"type":"header","benchmark":"longmemeval","variant":"s","seed":42,"run_label":"unit-test","arm":"both","judge_hydration_depth":10}"#
        let q1 = #"{"type":"question","question_id":"q001","question":"Capital?","gold_answer":"Paris","exact_payload":"The capital is Paris.","exact_payload_tokens":5,"dense_payload":null,"dense_payload_tokens":null}"#
        let q2 = #"{"type":"question","question_id":"q002","question":"River?","gold_answer":"Seine","exact_payload":"The Seine river.","exact_payload_tokens":4,"dense_payload":"It is the Seine.","dense_payload_tokens":5}"#
        let content = [header, q1, q2].joined(separator: "\n") + "\n"
        try Data(content.utf8).write(to: dumpURL)

        // `echo Paris` outputs "Paris\n" — matches gold "Paris" for q001 exact arm.
        try judgebatchRunBatch(
            inputsPath: dumpURL.path,
            judgeCmd: "echo Paris",
            grading: .substring,
            outDir: tempDir
        )

        // Find the verdict file.
        let files = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        let verdictFile = try #require(
            files.first(where: { $0.lastPathComponent.hasPrefix("judge-verdicts-unit-test-") }),
            "verdict file should be created in outDir")

        let verdictContent = try String(contentsOf: verdictFile, encoding: .utf8)
        let verdictLines = verdictContent.components(separatedBy: "\n").filter { !$0.isEmpty }

        // q001: exact arm only (dense_payload is null → skipped)
        // q002: exact arm + dense arm = 2 verdicts
        // Total: 3 verdict lines.
        #expect(verdictLines.count == 3, "3 arms judged: q001-exact, q002-exact, q002-dense")

        // Verify required fields on every verdict line.
        for lineStr in verdictLines {
            let lineData = Data(lineStr.utf8)
            let obj = try #require(
                try JSONSerialization.jsonObject(with: lineData) as? [String: Any])
            #expect(obj["question_id"] != nil, "verdict must have question_id")
            #expect(obj["arm"] != nil, "verdict must have arm")
            #expect(obj["gold_answer"] != nil, "verdict must have gold_answer")
            #expect(obj["judge_answer"] != nil, "verdict must have judge_answer")
            #expect(obj["correct"] != nil, "verdict must have correct field")
            #expect(obj["tokens"] != nil, "verdict must have tokens")
        }

        // q001 exact: "echo Paris" outputs "Paris" which substring-matches gold "Paris".
        let q001ExactStr = try #require(
            verdictLines.first(where: { $0.contains("\"q001\"") && $0.contains("\"exact\"") }))
        let q001Exact = try #require(
            try JSONSerialization.jsonObject(
                with: Data(q001ExactStr.utf8)) as? [String: Any])
        #expect(q001Exact["correct"] as? Bool == true,
                "q001 exact: 'Paris' substring-matches gold 'Paris'")
    }

    // Verifies that judgebatchRunBatch throws when the inputs file is missing.
    @Test("judgebatchRunBatch throws on missing inputs file")
    func throwsOnMissingInputs() {
        #expect(throws: (any Error).self) {
            try judgebatchRunBatch(
                inputsPath: "/nonexistent/path.jsonl",
                judgeCmd: "echo yes",
                grading: .substring,
                outDir: URL(fileURLWithPath: NSTemporaryDirectory())
            )
        }
    }

    // Verifies that judgebatchRunBatch throws when the file has no header line.
    @Test("judgebatchRunBatch throws when first line is not a header")
    func throwsOnMissingHeader() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DumpJudgeTests-noheader-\(Int.random(in: 100_000...999_999))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dumpURL = tempDir.appendingPathComponent("noheader.jsonl")
        let content = #"{"type":"question","question_id":"q001","question":"?","gold_answer":"x","exact_payload":"x","exact_payload_tokens":1,"dense_payload":null,"dense_payload_tokens":null}"# + "\n"
        try Data(content.utf8).write(to: dumpURL)

        #expect(throws: (any Error).self) {
            try judgebatchRunBatch(
                inputsPath: dumpURL.path,
                judgeCmd: "echo yes",
                grading: .substring,
                outDir: tempDir
            )
        }
    }
}
