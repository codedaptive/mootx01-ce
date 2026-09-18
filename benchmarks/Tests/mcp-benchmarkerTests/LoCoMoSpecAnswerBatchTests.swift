import Darwin
import Foundation
import Testing
@testable import mcp_benchmarker

@Suite("LoCoMo spec external reader seam")
struct LoCoMoSpecAnswerBatchTests {
    @Test("prompt keeps memories and requests official abstention phrase")
    func promptShape() {
        let prompt = loCoMoSpecReaderPrompt(
            question: "Where did Alice move?",
            category: 5,
            memoryTexts: ["Alice moved to Boston."])
        #expect(prompt.contains("[1] Alice moved to Boston."))
        #expect(prompt.contains("No information available."))
        #expect(prompt.hasSuffix("Answer:"))
    }

    @Test("answer batch scores a short answer with official token F1")
    func answerBatchScores() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("inputs.jsonl")
        let output = root.appendingPathComponent("scores.jsonl")
        let objects: [[String: Any]] = [
            ["type": "header", "benchmark": "locomo-spec", "seed": 1],
            [
                "type": "answer_input",
                "benchmark": "locomo-spec",
                "question_id": "sample_q1",
                "category": 1,
                "category_label": "single_hop",
                "question": "Where did Alice move?",
                "gold_answer": "Boston",
                "memory_texts": ["Alice moved to Boston."],
                "retrieved_drawer_ids": ["drawer-1"],
                "retrieved_dia_ids": ["S1"],
                "retrieved_ranks": [1],
            ],
        ]
        let text = try objects.map { object -> String in
            let data = try JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: input)

        try runLoCoMoSpecAnswerBatch(
            inputsPath: input.path,
            answerCmd: "echo Boston",
            outputPath: output.path,
            readerModel: "fixture-reader")

        let lines = try String(contentsOf: output, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        let header = try #require(
            JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        let record = try #require(
            JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        #expect(header["overall_token_f1"] as? Double == 1.0)
        #expect(header["reader_model"] as? String == "fixture-reader")
        #expect(header["offset"] as? Int == 0)
        #expect(header["input_row_count"] as? Int == 1)
        #expect(header["selected_input_count"] as? Int == 1)
        #expect((header["selected_input_sha256"] as? String)?.count == 64)
        // Two additive fields present on clean run.
        #expect(header["resumed_row_count"] as? Int == 0)
        #expect(header["progress_file"] as? String != nil)
        #expect(record["prediction"] as? String == "Boston")
        #expect(record["score"] as? Double == 1.0)
        #expect(record["retrieved_ranks"] as? [Int] == [1])
        let firstBytes = try Data(contentsOf: output)
        #expect(throws: (any Error).self) {
            try runLoCoMoSpecAnswerBatch(
                inputsPath: input.path,
                answerCmd: "echo Changed",
                outputPath: output.path,
                readerModel: "second-run")
        }
        #expect(try Data(contentsOf: output) == firstBytes)
    }

    @Test("offset and limit form restartable disjoint shards")
    func answerBatchShard() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("inputs.jsonl")
        let output = root.appendingPathComponent("scores.jsonl")
        let rows: [[String: Any]] = [
            ["type": "header", "benchmark": "locomo-spec", "seed": 1],
            ["type": "answer_input", "benchmark": "locomo-spec",
             "question_id": "q1", "category": 1, "category_label": "single_hop",
             "question": "First?", "gold_answer": "Boston", "memory_texts": [],
             "retrieved_drawer_ids": [], "retrieved_dia_ids": [], "retrieved_ranks": []],
            ["type": "answer_input", "benchmark": "locomo-spec",
             "question_id": "q2", "category": 1, "category_label": "single_hop",
             "question": "Second?", "gold_answer": "Boston", "memory_texts": [],
             "retrieved_drawer_ids": [], "retrieved_dia_ids": [], "retrieved_ranks": []],
        ]
        let text = try rows.map { row in
            String(decoding: try JSONSerialization.data(
                withJSONObject: row, options: [.sortedKeys]), as: UTF8.self)
        }.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: input)
        try runLoCoMoSpecAnswerBatch(
            inputsPath: input.path, answerCmd: "echo Boston",
            outputPath: output.path, limit: 1, offset: 1,
            readerModel: "fixture-reader")
        let outputRows = try String(contentsOf: output, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let scored = try #require(JSONSerialization.jsonObject(
            with: Data(outputRows[1].utf8)) as? [String: Any])
        #expect(scored["question_id"] as? String == "q2")
        let header = try #require(JSONSerialization.jsonObject(
            with: Data(outputRows[0].utf8)) as? [String: Any])
        #expect(header["input_row_count"] as? Int == 2)
        #expect(header["selected_input_count"] as? Int == 1)
        #expect(header["selected_input_sha256"] as? String ==
            "f1602616176fc13278447ceca02025229abb90798f1197d3ce4cd3835ba0c6a0")
    }

    @Test("malformed, wrong-kind, missing-field, duplicate, and zero-selection inputs fail loud")
    func malformedInputsFailLoud() throws {
        let valid = """
        {"benchmark":"locomo-spec","category":1,"category_label":"single_hop","gold_answer":"Boston","memory_texts":[],"question":"Where?","question_id":"q1","retrieved_dia_ids":[],"retrieved_drawer_ids":[],"retrieved_ranks":[],"type":"answer_input"}
        """
        let badBodies: [(String, String)] = [
            ("{not-json", "malformed JSON"),
            ("", "malformed JSON"),
            (valid.replacingOccurrences(of: "\"answer_input\"", with: "\"other\""), "wrong kind"),
            (valid.replacingOccurrences(of: "\"locomo-spec\"", with: "\"other-benchmark\""), "must be locomo-spec"),
            (valid.replacingOccurrences(of: "\"question\":\"Where?\",", with: ""), "missing non-empty string field 'question'"),
            (valid.replacingOccurrences(of: ",\"retrieved_ranks\":[]", with: ""), "retrieved_ranks"),
            (valid + "\n" + valid, "duplicate question_id"),
        ]
        for (body, expectedMessage) in badBodies {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let input = root.appendingPathComponent("inputs.jsonl")
            let output = root.appendingPathComponent("scores.jsonl")
            try Data(("{\"benchmark\":\"locomo-spec\",\"type\":\"header\"}\n" + body + "\n").utf8)
                .write(to: input)
            do {
                try runLoCoMoSpecAnswerBatch(
                    inputsPath: input.path, answerCmd: "echo Boston",
                    outputPath: output.path)
                Issue.record("expected input error containing \(expectedMessage)")
            } catch {
                #expect("\(error)".contains(expectedMessage))
            }
            #expect(!FileManager.default.fileExists(atPath: output.path))
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("inputs.jsonl")
        let output = root.appendingPathComponent("scores.jsonl")
        try Data(("{\"benchmark\":\"locomo-spec\",\"type\":\"header\"}\n" + valid + "\n").utf8)
            .write(to: input)
        #expect(throws: (any Error).self) {
            try runLoCoMoSpecAnswerBatch(
                inputsPath: input.path, answerCmd: "echo Boston",
                outputPath: output.path, offset: 2)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("answer-input dump is stable and excludes the reader command")
    func dumpShape() throws {
        let metadata = LoCoMoSpecRunMetadata(
            port: "swift", seed: 7, estateMode: "artifact-unit",
            targetScale: "unit", parallelUnits: 1, corpusDigest: "abc",
            totalQuestions: 1, conversationsUsed: 1, runLabel: "test",
            categoryCounts: [1: 1], unitIDsPath: nil, selectedCount: 1)
        let result = LoCoMoSpecRunResult(
            questionRecords: [],
            aggregate: loCoMoSpecAggregate(scores: []),
            metadata: metadata,
            answerInputs: [LoCoMoSpecAnswerInput(
                questionID: "q1", category: 1, categoryLabel: "single_hop",
                question: "Where?", goldAnswer: "Boston",
                memoryTexts: ["Alice moved to Boston."],
                retrievedDrawerIDs: ["d1"], retrievedRanks: [1],
                retrievedDiaIDs: ["S1"])])
        let first = try loCoMoSpecAnswerInputsJSONL(
            result, hydrationDepth: 10, hydrationTier: .distilled)
        let second = try loCoMoSpecAnswerInputsJSONL(
            result, hydrationDepth: 10, hydrationTier: .distilled)
        #expect(first == second)
        let rendered = String(decoding: first, as: UTF8.self)
        #expect(!rendered.contains("answer_cmd"))
        #expect(rendered.contains("\"retrieved_ranks\":[1]"))
    }

    // MARK: - Streaming and resume tests

    /// (a) Streaming: reader always exits 1 so all 3 rows fail.
    /// The progress file must contain 3 rows; the final file must not exist.
    @Test("streaming writes all-failure rows to progress file; no final file on all-failure")
    func streamingAllFailuresLeavesProgress() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let input = root.appendingPathComponent("inputs.jsonl")
        let output = root.appendingPathComponent("scores.jsonl")

        // 3-row input.
        let inputText = [
            "{\"benchmark\":\"locomo-spec\",\"type\":\"header\"}",
            "{\"benchmark\":\"locomo-spec\",\"category\":1,\"category_label\":\"single_hop\",\"gold_answer\":\"Boston\",\"memory_texts\":[],\"question\":\"First?\",\"question_id\":\"q1\",\"retrieved_dia_ids\":[],\"retrieved_drawer_ids\":[],\"retrieved_ranks\":[],\"type\":\"answer_input\"}",
            "{\"benchmark\":\"locomo-spec\",\"category\":1,\"category_label\":\"single_hop\",\"gold_answer\":\"Boston\",\"memory_texts\":[],\"question\":\"Second?\",\"question_id\":\"q2\",\"retrieved_dia_ids\":[],\"retrieved_drawer_ids\":[],\"retrieved_ranks\":[],\"type\":\"answer_input\"}",
            "{\"benchmark\":\"locomo-spec\",\"category\":1,\"category_label\":\"single_hop\",\"gold_answer\":\"Boston\",\"memory_texts\":[],\"question\":\"Third?\",\"question_id\":\"q3\",\"retrieved_dia_ids\":[],\"retrieved_drawer_ids\":[],\"retrieved_ranks\":[],\"type\":\"answer_input\"}",
        ].joined(separator: "\n") + "\n"
        try Data(inputText.utf8).write(to: input)

        // Reader always exits 1 — triggers the all-failures error path.
        do {
            try runLoCoMoSpecAnswerBatch(
                inputsPath: input.path,
                answerCmd: "sh -c 'exit 1'",
                outputPath: output.path,
                readerModel: "fail-reader")
            Issue.record("expected all-failures error")
        } catch {
            #expect("\(error)".contains("failed"))
        }

        // Final file must not exist.
        #expect(!FileManager.default.fileExists(atPath: output.path))

        // Progress file must exist with 3 failure rows.
        let progressPath = output.path + ".partial.jsonl"
        #expect(FileManager.default.fileExists(atPath: progressPath))
        let allProgressLines = try String(contentsOf: URL(fileURLWithPath: progressPath), encoding: .utf8)
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        // First line is the progress_header; the remaining 3 are failure rows.
        let progressLines = allProgressLines.filter {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?.keys.contains("question_id") == true
        }
        #expect(progressLines.count == 3)
        for line in progressLines {
            let obj = try #require(
                JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            #expect(obj["question_id"] as? String != nil)
            #expect(obj["error"] as? String != nil)
        }
    }

    /// (b) Resume: q1 and q2 already in progress file; re-run with a different reader.
    /// The final file's q1 and q2 predictions are the original ones;
    /// q3 is answered by the new reader. header.resumed_row_count == 2.
    @Test("resume reuses already-scored rows and calls reader only for missing rows")
    func resumeReusesAlreadyScoredRows() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let input = root.appendingPathComponent("inputs.jsonl")
        let output = root.appendingPathComponent("scores.jsonl")
        let progressPath = output.path + ".partial.jsonl"

        let inputText = [
            "{\"benchmark\":\"locomo-spec\",\"type\":\"header\"}",
            "{\"benchmark\":\"locomo-spec\",\"category\":1,\"category_label\":\"single_hop\",\"gold_answer\":\"Boston\",\"memory_texts\":[],\"question\":\"First?\",\"question_id\":\"q1\",\"retrieved_dia_ids\":[],\"retrieved_drawer_ids\":[],\"retrieved_ranks\":[],\"type\":\"answer_input\"}",
            "{\"benchmark\":\"locomo-spec\",\"category\":1,\"category_label\":\"single_hop\",\"gold_answer\":\"Boston\",\"memory_texts\":[],\"question\":\"Second?\",\"question_id\":\"q2\",\"retrieved_dia_ids\":[],\"retrieved_drawer_ids\":[],\"retrieved_ranks\":[],\"type\":\"answer_input\"}",
            "{\"benchmark\":\"locomo-spec\",\"category\":1,\"category_label\":\"single_hop\",\"gold_answer\":\"Boston\",\"memory_texts\":[],\"question\":\"Third?\",\"question_id\":\"q3\",\"retrieved_dia_ids\":[],\"retrieved_drawer_ids\":[],\"retrieved_ranks\":[],\"type\":\"answer_input\"}",
        ].joined(separator: "\n") + "\n"
        try Data(inputText.utf8).write(to: input)

        // Seed progress file with q1 and q2 already scored as "OriginalAnswer".
        // The file must carry a progress_header and be mode 0600 to pass security validation.
        let q1 = "{\"category\":1,\"gold_answer\":\"Boston\",\"prediction\":\"OriginalAnswer\",\"question_id\":\"q1\",\"retrieved_dia_ids\":[],\"retrieved_drawer_ids\":[],\"retrieved_ranks\":[],\"score\":0.0,\"type\":\"answer_score\"}"
        let q2 = "{\"category\":1,\"gold_answer\":\"Boston\",\"prediction\":\"OriginalAnswer\",\"question_id\":\"q2\",\"retrieved_dia_ids\":[],\"retrieved_drawer_ids\":[],\"retrieved_ranks\":[],\"score\":0.0,\"type\":\"answer_score\"}"
        // Compute the SHA-256 of the selected input rows the same way the production code does.
        // Mirror the production split: omitEmpty=false, strip trailing empty string, drop header.
        var inputLines = inputText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if inputLines.last == "" { inputLines.removeLast() }
        let selectedRawLines = Array(inputLines.dropFirst()) // drop header line
        let selectedInputBytes = selectedRawLines.joined(separator: "\n") + "\n"
        let digest = sha256HexOfString(selectedInputBytes)
        let readerIdentity = "resume-reader"
        let progressHeader = "{\"reader_identity\":\"\(readerIdentity)\",\"selected_input_sha256\":\"\(digest)\",\"type\":\"progress_header\"}"
        try Data((progressHeader + "\n" + q1 + "\n" + q2 + "\n").utf8).write(
            to: URL(fileURLWithPath: progressPath))
        // Set 0600 so the security ownership-and-permissions check passes.
        _ = chmod(progressPath, 0o600)

        // Run with a reader that answers "DifferentAnswer".
        try runLoCoMoSpecAnswerBatch(
            inputsPath: input.path,
            answerCmd: "echo DifferentAnswer",
            outputPath: output.path,
            readerModel: "resume-reader")

        let outputLines = try String(contentsOf: output, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        // header + 3 rows
        #expect(outputLines.count == 4)

        let hdr = try #require(
            JSONSerialization.jsonObject(with: Data(outputLines[0].utf8)) as? [String: Any])
        let row1 = try #require(
            JSONSerialization.jsonObject(with: Data(outputLines[1].utf8)) as? [String: Any])
        let row2 = try #require(
            JSONSerialization.jsonObject(with: Data(outputLines[2].utf8)) as? [String: Any])
        let row3 = try #require(
            JSONSerialization.jsonObject(with: Data(outputLines[3].utf8)) as? [String: Any])

        // q1 and q2 reused from progress file.
        #expect(row1["prediction"] as? String == "OriginalAnswer")
        #expect(row2["prediction"] as? String == "OriginalAnswer")
        // q3 answered by the new reader.
        #expect(row3["prediction"] as? String == "DifferentAnswer")
        // resumed_row_count == 2.
        #expect(hdr["resumed_row_count"] as? Int == 2)
        // Progress file removed after success.
        #expect(!FileManager.default.fileExists(atPath: progressPath))
    }

    /// (c) Clean-run byte-identity: the rows section of a clean run equals that of a resumed run.
    /// The header differs only in resumed_row_count (and the path in progress_file is the same shape).
    @Test("clean and resumed runs produce byte-identical row sections")
    func cleanAndResumedRowsByteIdentical() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let input = root.appendingPathComponent("inputs.jsonl")
        let cleanOutput = root.appendingPathComponent("clean.jsonl")
        let resumedOutput = root.appendingPathComponent("resumed.jsonl")

        let inputText = [
            "{\"benchmark\":\"locomo-spec\",\"type\":\"header\"}",
            "{\"benchmark\":\"locomo-spec\",\"category\":1,\"category_label\":\"single_hop\",\"gold_answer\":\"Boston\",\"memory_texts\":[],\"question\":\"First?\",\"question_id\":\"q1\",\"retrieved_dia_ids\":[],\"retrieved_drawer_ids\":[],\"retrieved_ranks\":[],\"type\":\"answer_input\"}",
            "{\"benchmark\":\"locomo-spec\",\"category\":1,\"category_label\":\"single_hop\",\"gold_answer\":\"Boston\",\"memory_texts\":[],\"question\":\"Second?\",\"question_id\":\"q2\",\"retrieved_dia_ids\":[],\"retrieved_drawer_ids\":[],\"retrieved_ranks\":[],\"type\":\"answer_input\"}",
        ].joined(separator: "\n") + "\n"
        try Data(inputText.utf8).write(to: input)

        // Clean run.
        try runLoCoMoSpecAnswerBatch(
            inputsPath: input.path,
            answerCmd: "echo Boston",
            outputPath: cleanOutput.path,
            readerModel: "test-reader")

        // Seed progress for the resumed run with q1 already scored (same answer).
        let progressPath = resumedOutput.path + ".partial.jsonl"
        let q1 = "{\"category\":1,\"gold_answer\":\"Boston\",\"prediction\":\"Boston\",\"question_id\":\"q1\",\"retrieved_dia_ids\":[],\"retrieved_drawer_ids\":[],\"retrieved_ranks\":[],\"score\":1,\"type\":\"answer_score\"}"
        // Compute the SHA-256 of the selected input rows the same way the production code does.
        // Mirror the production split: omitEmpty=false, strip trailing empty string, drop header.
        var inputLines2 = inputText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if inputLines2.last == "" { inputLines2.removeLast() }
        let selectedRawLines2 = Array(inputLines2.dropFirst()) // drop header line
        let selectedInputBytes2 = selectedRawLines2.joined(separator: "\n") + "\n"
        let digest2 = sha256HexOfString(selectedInputBytes2)
        let readerIdentity2 = "test-reader"
        let progressHeader2 = "{\"reader_identity\":\"\(readerIdentity2)\",\"selected_input_sha256\":\"\(digest2)\",\"type\":\"progress_header\"}"
        try Data((progressHeader2 + "\n" + q1 + "\n").utf8).write(to: URL(fileURLWithPath: progressPath))
        // Set 0600 so the security ownership-and-permissions check passes.
        _ = chmod(progressPath, 0o600)

        // Resumed run.
        try runLoCoMoSpecAnswerBatch(
            inputsPath: input.path,
            answerCmd: "echo Boston",
            outputPath: resumedOutput.path,
            readerModel: "test-reader")

        let cleanLines = try String(contentsOf: cleanOutput, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let resumedLines = try String(contentsOf: resumedOutput, encoding: .utf8)
            .split(separator: "\n").map(String.init)

        // Row bytes (all lines after the header) must be identical.
        #expect(Array(cleanLines.dropFirst()) == Array(resumedLines.dropFirst()))

        // Header: resumed_row_count differs; all other score fields match.
        let cleanHdr = try #require(
            JSONSerialization.jsonObject(with: Data(cleanLines[0].utf8)) as? [String: Any])
        let resumedHdr = try #require(
            JSONSerialization.jsonObject(with: Data(resumedLines[0].utf8)) as? [String: Any])
        #expect(cleanHdr["resumed_row_count"] as? Int == 0)
        #expect(resumedHdr["resumed_row_count"] as? Int == 1)
        #expect(cleanHdr["overall_token_f1"] as? Double == resumedHdr["overall_token_f1"] as? Double)
        #expect(cleanHdr["selected_input_sha256"] as? String == resumedHdr["selected_input_sha256"] as? String)
        #expect(cleanHdr["questions"] as? Int == resumedHdr["questions"] as? Int)
        #expect(cleanHdr["failures"] as? Int == resumedHdr["failures"] as? Int)
    }
}
