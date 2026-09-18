import Darwin
import Testing
import Foundation
@testable import mcp_benchmarker

// LMESpecAnswerBatchTests.swift — shape tests for the lme-spec reader-model flow.
//
// Scope: pure-logic tests; no live MCP client, no estate, no external network.
// Reader subprocess is exercised via `sh -c 'printf …'` so the test suite
// verifies the full data path without any external dependency.
//
//   §1  lmeSpecAnswerInputLine: dump line carries all required keys
//   §2  runLMESpecAnswerBatch: judge_ready shape from a fake answer cmd
//
// Run with:
//   swift test --scratch-path .build-lmerd --filter LMESpecAnswerBatch

@Suite("lme-spec answer-input dump — line shape")
struct LMESpecAnswerInputLineTests {

    @Test("lmeSpecAnswerInputLine: all required keys present, valid JSON, trailing newline")
    func answerInputLineShape() throws {
        // Full question stub matching LMESpecQuestion's memberwise initializer.
        let q = LMESpecQuestion(
            questionID: "q_single_session_user_001",
            questionType: "single-session-user",
            question: "What did Alice say about the project?",
            answer: "She liked it",
            questionDate: "2024-05-01",
            haystackDates: [],
            haystackSessionIDs: [],
            haystackSessions: [],
            answerSessionIDs: []
        )
        let memTexts    = ["Alice mentioned the project looked great.", "Bob agreed."]
        let drawerIDs   = ["uuid-a1", "uuid-b2"]
        let synthDigest = "She liked it"

        let line = try #require(
            lmeSpecAnswerInputLine(
                question: q,
                memoryTexts: memTexts,
                retrievedDrawerIDs: drawerIDs,
                hypothesisDigest: synthDigest),
            "lmeSpecAnswerInputLine must return non-nil for valid inputs")

        #expect(line.hasSuffix("\n"), "answer_input line must end with newline")

        let data = Data(line.utf8.dropLast())
        let obj = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "answer_input line must be valid JSON")

        // Required keys per the brief (§1 deliver).
        #expect(obj["type"] as? String == "answer_input",    "type must be answer_input")
        #expect(obj["benchmark"] as? String == "lme-spec",   "benchmark must be lme-spec")
        #expect(obj["question_id"] as? String == q.questionID)
        #expect(obj["question_type"] as? String == q.questionType)
        #expect(obj["base_question_type"] as? String != nil, "base_question_type must be present")
        #expect(obj["is_abstention"] != nil,                 "is_abstention must be present")
        #expect(obj["question"] as? String == q.question)
        #expect(obj["correct_answer"] as? String == q.answer)
        #expect(obj["memory_texts"] as? [String] == memTexts)
        #expect(obj["retrieved_drawer_ids"] as? [String] == drawerIDs)
        #expect(obj["hypothesis_digest"] as? String == synthDigest)
        #expect(obj["question_date"] as? String == q.questionDate)
    }

    @Test("lmeSpecAnswerInputLine: nil hypothesis_digest encodes as NSNull")
    func answerInputLineNilDigest() throws {
        let q = LMESpecQuestion(
            questionID: "q_abs_001",
            questionType: "single-session-user_abs",
            question: "Did Alice mention the project?",
            answer: "I don't know",
            questionDate: "2024-05-01",
            haystackDates: [],
            haystackSessionIDs: [],
            haystackSessions: [],
            answerSessionIDs: []
        )
        let line = try #require(lmeSpecAnswerInputLine(
            question: q, memoryTexts: [], retrievedDrawerIDs: [], hypothesisDigest: nil))

        let data = Data(line.utf8.dropLast())
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        // hypothesis_digest must be encoded as JSON null (NSNull) when nil.
        let digestValue = obj["hypothesis_digest"]
        #expect(digestValue is NSNull, "nil hypothesis_digest must encode as JSON null")
    }
}

@Suite("lme-spec answer-batch — judge_ready shape")
struct LMESpecAnswerBatchRunnerTests {

    @Test("runLMESpecAnswerBatch: judge_ready carries hypothesis, anscheck_prompt, question_id")
    func answerBatchJudgeReadyShape() throws {
        let tmp = FileManager.default.temporaryDirectory.path

        // Build a minimal two-line dump: header + one answer_input line.
        let header: [String: Any] = [
            "type": "header",
            "benchmark": "lme-spec",
            "variant": "s",
            "seed": 42,
            "run_label": "lme-spec-s-seed42",
            "answer_hydration_depth": 10,
        ]
        let answerInput: [String: Any] = [
            "type": "answer_input",
            "benchmark": "lme-spec",
            "question_id": "q_test_001",
            "question_type": "single-session-user",
            "base_question_type": "single-session-user",
            "is_abstention": false,
            "question": "What color is the sky?",
            "question_date": "2024-01-01",
            "correct_answer": "Blue",
            "memory_texts": ["The sky looks blue today."],
            "retrieved_drawer_ids": ["drawer-uuid-1"],
            "hypothesis_digest": "Blue",
        ]

        var dumpLines = ""
        if let hd = try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]),
           let hs = String(data: hd, encoding: .utf8) { dumpLines += hs + "\n" }
        if let ad = try? JSONSerialization.data(withJSONObject: answerInput, options: [.sortedKeys]),
           let as2 = String(data: ad, encoding: .utf8) { dumpLines += as2 + "\n" }

        let inputsPath = tmp + "/lmerd_test_inputs_\(UInt32.random(in: 0..<UInt32.max)).jsonl"
        let outputPath = tmp + "/lmerd_test_out_\(UInt32.random(in: 0..<UInt32.max)).jsonl"
        defer {
            try? FileManager.default.removeItem(atPath: inputsPath)
            try? FileManager.default.removeItem(atPath: outputPath)
        }

        try Data(dumpLines.utf8).write(to: URL(fileURLWithPath: inputsPath))

        // Reader cmd: echoes a fixed answer so the test is deterministic.
        let answerCmd = "sh -c 'printf \"Blue\"'"

        try runLMESpecAnswerBatch(
            inputsPath: inputsPath,
            answerCmd: answerCmd,
            outputPath: outputPath)

        // Read and parse the output.
        let outContent = try #require(
            String(data: try Data(contentsOf: URL(fileURLWithPath: outputPath)), encoding: .utf8),
            "output file must be readable")

        let outLines = outContent.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(outLines.count == 2, "output must have header + one judge_ready line")

        // Validate the judge_ready line.
        let jrData = try #require(outLines[1].data(using: .utf8))
        let jr = try #require(
            try JSONSerialization.jsonObject(with: jrData) as? [String: Any])

        #expect(jr["type"] as? String == "judge_ready")
        #expect(jr["question_id"] as? String == "q_test_001")
        #expect(jr["hypothesis"] as? String == "Blue",
                "hypothesis must be the reader model's stdout")
        let anscheckStr = jr["anscheck_prompt"] as? String
        #expect(anscheckStr != nil && !anscheckStr!.isEmpty,
                "anscheck_prompt must be non-empty")
        // anscheck_prompt must contain the hypothesis text (reader's answer).
        #expect(anscheckStr?.contains("Blue") == true,
                "anscheck_prompt must include the reader's hypothesis")
        #expect(jr["base_question_type"] as? String == "single-session-user")
        #expect(jr["is_abstention"] as? Bool == false)
    }

    @Test("runLMESpecAnswerBatch: offset and limit select answer rows")
    func answerBatchHonorsOffsetAndLimit() throws {
        let tmp = FileManager.default.temporaryDirectory.path
        let inputsPath = tmp + "/lmerd_slice_inputs_\(UInt32.random(in: 0..<UInt32.max)).jsonl"
        let outputPath = tmp + "/lmerd_slice_out_\(UInt32.random(in: 0..<UInt32.max)).jsonl"
        defer {
            try? FileManager.default.removeItem(atPath: inputsPath)
            try? FileManager.default.removeItem(atPath: outputPath)
        }

        let header: [String: Any] = ["type": "header", "benchmark": "lme-spec"]
        func row(_ id: String) -> [String: Any] {
            [
                "type": "answer_input", "benchmark": "lme-spec",
                "question_id": id, "question_type": "single-session-user",
                "question": "What color is the sky?", "correct_answer": "Blue",
                "memory_texts": ["The sky is blue."],
            ]
        }
        let objects = [header, row("q_first"), row("q_second"), row("q_third")]
        let dump = try objects.map {
            String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]),
                   as: UTF8.self)
        }.joined(separator: "\n") + "\n"
        try Data(dump.utf8).write(to: URL(fileURLWithPath: inputsPath))

        try runLMESpecAnswerBatch(
            inputsPath: inputsPath,
            answerCmd: "sh -c 'printf \"Blue\"'",
            outputPath: outputPath,
            limit: 1,
            offset: 1)

        let output = try String(contentsOfFile: outputPath, encoding: .utf8)
        #expect(output.contains("q_second"))
        #expect(!output.contains("q_first"))
        #expect(!output.contains("q_third"))
    }
}

// MARK: - Resume security hardening tests

@Suite("LME-spec answer-batch resume security")
struct LMESpecAnswerBatchResumeSecurityTests {

    @Test("reader command secrets never enter resume headers")
    func opaqueReaderResumeIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input.jsonl").path
        let output = root.appendingPathComponent("output.jsonl").path
        try makeInputsFile(at: input, questionIDs: [])
        let command = "TOKEN=synthetic-secret printf Gold"
        try runLMESpecAnswerBatch(inputsPath: input, answerCmd: command, outputPath: output)
        let before = try String(contentsOfFile: output, encoding: .utf8)
        #expect(!before.contains("synthetic-secret"))
        #expect(before.contains("sha256:" + sha256HexOfString(command)))
        try runLMESpecAnswerBatch(inputsPath: input, answerCmd: command, outputPath: output)
        #expect(try String(contentsOfFile: output, encoding: .utf8) == before)
        #expect(throws: (any Error).self) {
            try runLMESpecAnswerBatch(inputsPath: input, answerCmd: command + " changed", outputPath: output)
        }
    }

    // MARK: Helpers

    private func makeInputsFile(at path: String, questionIDs: [String]) throws {
        let header = "{\"benchmark\":\"lme-spec\",\"type\":\"header\"}"
        var lines = [header]
        for qid in questionIDs {
            lines.append(
                "{\"type\":\"answer_input\",\"benchmark\":\"lme-spec\",\"question_id\":\"\(qid)\"" +
                ",\"question\":\"What?\",\"gold\":\"Gold\",\"hypothesis\":\"Hyp\"" +
                ",\"hypothesis_digest\":null,\"retrieved_drawer_ids\":[],\"retrieved_dia_ids\":[]" +
                ",\"retrieved_ranks\":[]}"
            )
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: Tests

    @Test("resume rejected when output file has wrong permissions")
    func resumeRejectedOnBadPermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let inputs = root.appendingPathComponent("inputs.jsonl").path
        let output = root.appendingPathComponent("out.jsonl").path
        try makeInputsFile(at: inputs, questionIDs: ["q1"])

        // Seed a partial output with wrong permissions (0644 instead of 0600).
        let seedHeader = "{\"type\":\"header\",\"benchmark\":\"lme-spec\",\"selected_input_sha256\":\"x\",\"reader_identity\":\"x\"}"
        try (seedHeader + "\n").write(toFile: output, atomically: true, encoding: .utf8)
        _ = chmod(output, 0o644)

        // Attempt to run answer-batch on the existing file.
        #expect(throws: (any Error).self) {
            try runLMESpecAnswerBatch(
                inputsPath: inputs,
                answerCmd: "echo Gold",
                outputPath: output,
                judgeModel: "test-judge")
        }
    }

    @Test("resume rejected when stored digest does not match selected input")
    func resumeRejectedOnDigestMismatch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let inputs = root.appendingPathComponent("inputs.jsonl").path
        let output = root.appendingPathComponent("out.jsonl").path
        try makeInputsFile(at: inputs, questionIDs: ["q1"])

        // Seed output with a wrong digest.
        let seedHeader = "{\"type\":\"header\",\"benchmark\":\"lme-spec\",\"selected_input_sha256\":\"wrong-digest\",\"reader_identity\":\"echo Gold\"}"
        let fd = Darwin.open(output, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard fd >= 0 else { Issue.record("could not create seed file"); return }
        let data = Array((seedHeader + "\n").utf8)
        data.withUnsafeBytes { _ = write(fd, $0.baseAddress!, $0.count) }
        Darwin.close(fd)

        #expect(throws: (any Error).self) {
            try runLMESpecAnswerBatch(
                inputsPath: inputs,
                answerCmd: "echo Gold",
                outputPath: output,
                judgeModel: "test-judge")
        }
    }

    @Test("resume rejected when stored reader identity does not match current command")
    func resumeRejectedOnIdentityMismatch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let inputs = root.appendingPathComponent("inputs.jsonl").path
        let output = root.appendingPathComponent("out.jsonl").path
        try makeInputsFile(at: inputs, questionIDs: ["q1"])

        // Compute the correct digest for the single input line.
        let q1Line = "{\"type\":\"answer_input\",\"benchmark\":\"lme-spec\",\"question_id\":\"q1\"" +
            ",\"question\":\"What?\",\"gold\":\"Gold\",\"hypothesis\":\"Hyp\"" +
            ",\"hypothesis_digest\":null,\"retrieved_drawer_ids\":[],\"retrieved_dia_ids\":[]" +
            ",\"retrieved_ranks\":[]}"
        let correctDigest = sha256HexOfString(q1Line + "\n")

        // Seed output with the correct digest but a different reader identity.
        let seedHeader: [String: Any] = [
            "type": "header",
            "benchmark": "lme-spec",
            "selected_input_sha256": correctDigest,
            "reader_identity": "different-command",
        ]
        let headerData = try JSONSerialization.data(withJSONObject: seedHeader, options: [.sortedKeys])
        let headerStr = String(data: headerData, encoding: .utf8)! + "\n"
        let fd = Darwin.open(output, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard fd >= 0 else { Issue.record("could not create seed file"); return }
        let bytes = Array(headerStr.utf8)
        bytes.withUnsafeBytes { _ = write(fd, $0.baseAddress!, $0.count) }
        Darwin.close(fd)

        #expect(throws: (any Error).self) {
            try runLMESpecAnswerBatch(
                inputsPath: inputs,
                answerCmd: "echo Gold",
                outputPath: output,
                judgeModel: "test-judge")
        }
    }
}
