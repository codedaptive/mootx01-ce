import Testing
import Foundation
@testable import mcp_benchmarker

// AnswerBatchTests.swift — tests for the answer-batch subcommand (runAnswerBatch).
//
// Four cases:
//   1. convomem-spec dispatch: fixture dump of 2 records + `cat` as answer cmd;
//      verifies the function reaches runConvoMemSpecAnswerDump and writes output.
//   2. membench-spec dispatch: 2 records, fake cmd emitting "Answer: B"; output
//      lines parse back through loadConsumedAnswers.
//   3. unknown benchmark: error naming the unknown value.
//   4. all-failed exits non-zero (membench path, cmd always fails).
//
// No live estate, no subprocess calls against a real model. The `cat` fake answer
// command echos stdin, which does not contain a valid JSON letter, so convomem-spec
// records simply skip (no output) — the test only checks that dispatch succeeds
// without throwing.

// MARK: - Helpers

/// Creates a temporary file with the given content and returns its path.
/// The file is removed after the test body returns via a defer.
private func writeTempFile(_ content: String, suffix: String = ".jsonl") throws -> String {
    let dir = FileManager.default.temporaryDirectory
    let path = dir.appendingPathComponent(
        UUID().uuidString + suffix).path
    guard FileManager.default.createFile(atPath: path,
                                         contents: Data(content.utf8),
                                         attributes: nil) else {
        throw MCPError(description: "AnswerBatchTests: cannot write temp file at \(path)")
    }
    return path
}

/// Returns the path for a temporary output file that does not yet exist.
private func tempOutputPath(suffix: String = ".jsonl") -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + suffix).path
}

// MARK: - convomem-spec dispatch

@Suite("answer-batch: convomem-spec dispatch")
struct AnswerBatchConvoMemTests {

    // Fixture: 2 answer_input records in convomem-spec format. The fake answer
    // cmd is `cat`, which echoes the prompt back. `cat` output is not a valid
    // letter, so runConvoMemSpecAnswerDump skips the records silently — the
    // test verifies that dispatch reaches the runner without throwing.
    @Test("convomem dispatch reaches runConvoMemSpecAnswerDump without throwing")
    func convoMemDispatchSucceeds() throws {
        let header: [String: Any] = [
            "type": "header",
            "benchmark": "convomem-spec",
            "run_label": "test-run",
            "seed": 1,
        ]
        let record1: [String: Any] = [
            "type": "answer_input",
            "query_id": "q001",
            "evidence_type": "user_evidence",
            "question": "What does the user prefer?",
            "memory_texts": ["The user prefers coffee over tea."],
            "correct_answer": "A",
        ]
        let record2: [String: Any] = [
            "type": "answer_input",
            "query_id": "q002",
            "evidence_type": "user_evidence",
            "question": "Which drink was mentioned?",
            "memory_texts": ["Tea and coffee were both discussed."],
            "correct_answer": "B",
        ]
        let lines = [header, record1, record2].compactMap { obj -> String? in
            guard let d = try? JSONSerialization.data(withJSONObject: obj, options: []),
                  let s = String(data: d, encoding: .utf8) else { return nil }
            return s
        }.joined(separator: "\n")

        let inputPath = try writeTempFile(lines)
        let outputPath = tempOutputPath()
        defer {
            try? FileManager.default.removeItem(atPath: inputPath)
            try? FileManager.default.removeItem(atPath: outputPath)
        }

        // `cat` echoes stdin; the output is not a valid letter, so the records
        // are skipped silently. Dispatch must not throw.
        #expect(throws: Never.self) {
            try runAnswerBatch([
                "--inputs", inputPath,
                "--answer-cmd", "cat",
                "--out", outputPath,
            ])
        }
    }
}

// MARK: - membench-spec dispatch

@Suite("answer-batch: membench-spec dispatch")
struct AnswerBatchMemBenchTests {

    // Fake answer command: emits "Answer: B" on stdout and exits 0.
    // MemBenchAnswerConstraint.parseAnswerChoice's fallback strips spaces and
    // newlines, leaving "Answer:B" which is not a valid letter alone. So the
    // command must emit bare "B" or JSON {"choice":"B"} to parse.
    //
    // Use `echo B` (which emits "B\n") — the fallback path strips \n and finds
    // the single-character letter "B".

    /// Builds a membench-spec answer-inputs JSONL string with N qa records.
    private func buildMemBenchDump(records: [(id: String, prompt: String)]) -> String {
        let header: [String: Any] = [
            "type": "header",
            "benchmark": "membench-spec",
            "run_label": "test-label",
            "agent": "FirstAgent",
        ]
        var objs: [[String: Any]] = [header]
        for rec in records {
            objs.append([
                "type": "qa",
                "item_id": rec.id,
                "category": "single_session_user",
                "agent": "FirstAgent",
                "prompt": rec.prompt,
                "ground_truth": "B",
                "item_recall": 1.0,
            ])
        }
        return objs.compactMap { obj -> String? in
            guard let d = try? JSONSerialization.data(withJSONObject: obj, options: []),
                  let s = String(data: d, encoding: .utf8) else { return nil }
            return s
        }.joined(separator: "\n")
    }

    /// Runs answer-batch with membench fixture and `echo B` as the answer cmd.
    /// Verifies that the two output lines parse back through loadConsumedAnswers.
    @Test("membench output lines parse back through loadConsumedAnswers")
    func membenchOutputParsesBack() throws {
        let dump = buildMemBenchDump(records: [
            (id: "item_001", prompt: "Q1: which choice?"),
            (id: "item_002", prompt: "Q2: which choice?"),
        ])
        let inputPath = try writeTempFile(dump)
        let outputPath = tempOutputPath()
        defer {
            try? FileManager.default.removeItem(atPath: inputPath)
            try? FileManager.default.removeItem(atPath: outputPath)
        }

        // `echo B` emits "B\n"; the fallback path in parseAnswerChoice strips
        // the newline, leaving "B" — a valid letter.
        #expect(throws: Never.self) {
            try runAnswerBatch([
                "--inputs", inputPath,
                "--answer-cmd", "echo B",
                "--out", outputPath,
            ])
        }

        // Verify output via loadConsumedAnswers.
        let consumed = try loadConsumedAnswers(URL(fileURLWithPath: outputPath))
        #expect(consumed.count == 2,
                "both records must be present in consumed-answers output")
        #expect(consumed["item_001"] == "B",
                "item_001 must have answer B")
        #expect(consumed["item_002"] == "B",
                "item_002 must have answer B")
    }

    /// --limit N restricts the number of qa records processed.
    @Test("--limit restricts records processed")
    func limitCapsRecords() throws {
        let dump = buildMemBenchDump(records: [
            (id: "item_001", prompt: "Q1"),
            (id: "item_002", prompt: "Q2"),
        ])
        let inputPath = try writeTempFile(dump)
        let outputPath = tempOutputPath()
        defer {
            try? FileManager.default.removeItem(atPath: inputPath)
            try? FileManager.default.removeItem(atPath: outputPath)
        }

        try runAnswerBatch([
            "--inputs", inputPath,
            "--answer-cmd", "echo B",
            "--out", outputPath,
            "--limit", "1",
        ])

        let consumed = try loadConsumedAnswers(URL(fileURLWithPath: outputPath))
        #expect(consumed.count == 1,
                "--limit 1 must restrict output to one record")
    }
}

// MARK: - unknown benchmark errors

@Suite("answer-batch: unknown benchmark")
struct AnswerBatchUnknownBenchmarkTests {

    @Test("unknown benchmark name errors with a message naming it")
    func unknownBenchmarkErrors() throws {
        let header: [String: Any] = [
            "type": "header",
            "benchmark": "not-a-real-spec",
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: header, options: []),
              let s = String(data: d, encoding: .utf8) else {
            Issue.record("JSON serialisation failed"); return
        }
        let inputPath = try writeTempFile(s)
        let outputPath = tempOutputPath()
        defer {
            try? FileManager.default.removeItem(atPath: inputPath)
            try? FileManager.default.removeItem(atPath: outputPath)
        }

        var threw = false
        var errorDesc = ""
        do {
            try runAnswerBatch([
                "--inputs", inputPath,
                "--answer-cmd", "echo B",
                "--out", outputPath,
            ])
        } catch let e as MCPError {
            threw = true
            errorDesc = e.description
        } catch {
            threw = true
            errorDesc = "\(error)"
        }
        #expect(threw, "unknown benchmark must throw")
        #expect(errorDesc.contains("not-a-real-spec"),
                "error must name the unknown benchmark value; got: \(errorDesc)")
    }
}

// MARK: - all-failed exits non-zero

@Suite("answer-batch: all-failed exits non-zero")
struct AnswerBatchAllFailedTests {

    /// When every record fails (answer cmd exits non-zero), runAnswerBatch throws.
    @Test("all-failed membench records causes runAnswerBatch to throw")
    func allFailedThrows() throws {
        let header: [String: Any] = [
            "type": "header",
            "benchmark": "membench-spec",
            "run_label": "fail-test",
            "agent": "FirstAgent",
        ]
        let record: [String: Any] = [
            "type": "qa",
            "item_id": "item_fail",
            "category": "single_session_user",
            "agent": "FirstAgent",
            "prompt": "Q?",
            "ground_truth": "A",
            "item_recall": 0.0,
        ]
        let lines = [header, record].compactMap { obj -> String? in
            guard let d = try? JSONSerialization.data(withJSONObject: obj, options: []),
                  let s = String(data: d, encoding: .utf8) else { return nil }
            return s
        }.joined(separator: "\n")

        let inputPath = try writeTempFile(lines)
        let outputPath = tempOutputPath()
        defer {
            try? FileManager.default.removeItem(atPath: inputPath)
            try? FileManager.default.removeItem(atPath: outputPath)
        }

        // `false` exits 1; lmeRunJudge throws on non-zero exit; answer is nil.
        var threw = false
        do {
            try runAnswerBatch([
                "--inputs", inputPath,
                "--answer-cmd", "false",
                "--out", outputPath,
            ])
        } catch {
            threw = true
        }
        #expect(threw, "all-failed must cause runAnswerBatch to throw")
    }
}
