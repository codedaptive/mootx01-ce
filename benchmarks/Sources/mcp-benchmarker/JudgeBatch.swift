// JudgeBatch.swift
//
// `judge-batch` subcommand: reads a pre-judge JSONL file produced by
// `--dump-judge-inputs` and runs the judge offline with no estate or
// mootx01 binary required.
//
// Usage:
//   mcp-benchmarker judge-batch
//     --inputs <path.jsonl>
//     --judge-cmd <cmd>               (or MOOT_BENCH_JUDGE_CMD env var)
//     [--judge-grading substring|verdict]   default: substring
//     [--out <dir>]                   default: current directory
//
// Output: judge-verdicts-<run_label>-<iso8601>.jsonl in --out.
// Verdict line schema:
//   {"question_id":"…","arm":"exact","gold_answer":"…","judge_answer":"…","correct":true,"tokens":412}

import Foundation

// MARK: - Public entry point (called from CLI.swift dispatch)

/// Entry point for the `judge-batch` subcommand.
///
/// Reads a JSONL dump file produced by `--dump-judge-inputs`, runs the LLM
/// judge offline per arm per question, writes verdict lines, and prints a
/// summary. No estate or mootx01 binary is required.
func runJudgeBatch(_ args: [String]) throws {
    guard let inputsPath = optionValue("--inputs", in: args) else {
        throw MCPError(description: "missing required option --inputs")
    }

    // MOOT_BENCH_JUDGE_CMD env var takes precedence over --judge-cmd flag.
    // The flag value is visible in `ps` argv; the env var is not.
    guard let judgeCmd =
        ProcessInfo.processInfo.environment["MOOT_BENCH_JUDGE_CMD"]
        ?? optionValue("--judge-cmd", in: args) else {
        throw MCPError(description:
            "missing required judge command: set MOOT_BENCH_JUDGE_CMD or pass --judge-cmd")
    }

    let gradingStr = optionValue("--judge-grading", in: args) ?? "substring"
    let grading: LMEJudgeGrading
    switch gradingStr {
    case "substring": grading = .substring
    case "verdict":   grading = .verdict
    default:
        throw MCPError(description:
            "--judge-grading must be 'substring' or 'verdict'; got '\(gradingStr)'")
    }

    let outDirStr = optionValue("--out", in: args)
    let outDir = outDirStr.map { URL(fileURLWithPath: $0) }
        ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

    try judgebatchRunBatch(
        inputsPath: inputsPath,
        judgeCmd: judgeCmd,
        grading: grading,
        outDir: outDir
    )
}

// MARK: - Batch runner

/// Core logic: read JSONL, judge each arm payload, write verdict file.
func judgebatchRunBatch(
    inputsPath: String,
    judgeCmd: String,
    grading: LMEJudgeGrading,
    outDir: URL
) throws {
    guard let rawContent = FileManager.default.contents(atPath: inputsPath),
          let content = String(data: rawContent, encoding: .utf8) else {
        throw MCPError(description: "cannot read inputs file at '\(inputsPath)'")
    }

    let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
    guard !lines.isEmpty else {
        throw MCPError(description: "inputs file is empty: '\(inputsPath)'")
    }

    // Parse the header line (must be first).
    guard let headerData = lines[0].data(using: .utf8),
          let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
          let headerType = header["type"] as? String, headerType == "header" else {
        throw MCPError(description:
            "first line of inputs file is not a valid header object")
    }
    let runLabel = header["run_label"] as? String ?? "unknown"

    var verdictLines: [String] = []
    var totalJudged = 0
    var totalCorrect = 0

    for line in lines.dropFirst() {
        guard let lineData = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let lineType = obj["type"] as? String, lineType == "question" else {
            continue
        }
        guard let questionID = obj["question_id"] as? String,
              let questionText = obj["question"] as? String,
              let goldAnswer = obj["gold_answer"] as? String else {
            continue
        }

        // Judge each non-null arm.
        let arms: [(arm: String, payload: String?, tokens: Int?)] = [
            ("exact",
             obj["exact_payload"] as? String,
             obj["exact_payload_tokens"] as? Int),
            ("dense",
             obj["dense_payload"] as? String,
             obj["dense_payload_tokens"] as? Int),
        ]
        for (armName, payload, tokenCount) in arms {
            guard let payload = payload, !payload.isEmpty else { continue }
            let prompt = lmeJudgePrompt(question: questionText, payload: payload)
            let answer: String
            do {
                answer = try lmeRunJudge(cmd: judgeCmd, prompt: prompt)
            } catch {
                FileHandle.standardError.write(Data(
                    "[judge-batch] judge failed for \(questionID)/\(armName): \(error)\n".utf8))
                continue
            }
            let correct: Bool = judgebatchGrade(
                answer: answer,
                goldAnswer: goldAnswer,
                questionText: questionText,
                grading: grading,
                judgeCmd: judgeCmd
            )
            totalJudged += 1
            if correct { totalCorrect += 1 }
            let verdict: [String: Any] = [
                "question_id": questionID,
                "arm": armName,
                "gold_answer": goldAnswer,
                "judge_answer": answer,
                "correct": correct,
                "tokens": tokenCount ?? lmeEstimateTokens(payload),
            ]
            if let vData = try? JSONSerialization.data(withJSONObject: verdict, options: [.sortedKeys]),
               let vLine = String(data: vData, encoding: .utf8) {
                verdictLines.append(vLine)
            }
        }
    }

    // Write verdict file.
    let iso8601: String = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "+", with: "Z")
    }()
    // Sanitize runLabel: strip path separators so a crafted run_label cannot
    // write the verdict file outside --out. Also create with owner-only permissions.
    let safeRunLabel = runLabel
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "\\", with: "_")
        .replacingOccurrences(of: "..", with: "_")
    let verdictFilename = "judge-verdicts-\(safeRunLabel)-\(iso8601).jsonl"
    let verdictURL = outDir.appendingPathComponent(verdictFilename)
    let fileContent = verdictLines.joined(separator: "\n")
        + (verdictLines.isEmpty ? "" : "\n")
    // Create with 0o600 so other local users cannot read judge payloads.
    FileManager.default.createFile(atPath: verdictURL.path, contents: nil,
                                   attributes: [.posixPermissions: 0o600 as NSNumber])
    try Data(fileContent.utf8).write(to: verdictURL)

    // Print summary.
    let accuracy = totalJudged > 0
        ? String(format: "%.4f", Double(totalCorrect) / Double(totalJudged))
        : "N/A"
    let summary = """
        [judge-batch] run complete
          questions judged: \(totalJudged)
          correct:          \(totalCorrect)
          accuracy:         \(accuracy)
          verdicts written: \(verdictURL.path)

        """
    FileHandle.standardOutput.write(Data(summary.utf8))
}

// MARK: - Grading helper

/// Grades one judge answer against the gold answer, applying the configured
/// grading mode. Verdict mode spends a second judge call for an explicit
/// CORRECT/INCORRECT decision and falls back to substring when unparseable.
private func judgebatchGrade(
    answer: String,
    goldAnswer: String,
    questionText: String,
    grading: LMEJudgeGrading,
    judgeCmd: String
) -> Bool {
    switch grading {
    case .substring:
        return lmeGradeJudgeAnswer(answer, goldAnswer: goldAnswer)
    case .verdict:
        let vPrompt = lmeVerdictPrompt(
            question: questionText,
            goldAnswer: goldAnswer,
            candidateAnswer: answer
        )
        if let reply = try? lmeRunJudge(cmd: judgeCmd, prompt: vPrompt),
           let verdict = lmeParseVerdict(reply) {
            return verdict
        }
        // Verdict unparseable — degrade to substring grading.
        FileHandle.standardError.write(Data(
            "[judge-batch] verdict unparseable — falling back to substring\n".utf8))
        return lmeGradeJudgeAnswer(answer, goldAnswer: goldAnswer)
    }
}
