import Darwin
import Foundation

// LMESpecAnswerBatch.swift — Offline answer-batch consumer for lme-spec answer-input dumps.
//
// Role: reads the JSONL dump produced by `lme-spec --dump-answer-inputs`, runs a
// reader model subprocess for each question, builds the §2 anscheck prompt from
// the reader's answer, and writes judge_ready JSONL lines. The output is consumed
// by judge-sessions.py unchanged — the anscheck_prompt field in
// each judge_ready line is byte-exact from the existing per-type anscheck builder.
//
// Pipeline position:
//   lme-spec --dump-answer-inputs answers.jsonl
//   answer-batch --inputs answers.jsonl --answer-cmd "..." --out judge_ready.jsonl
//   judge-sessions.py  (consumes judge_ready.jsonl unchanged)
//
// Reader prompt (lme-spec): the question and memory_texts, asking for a direct
// prose answer — no letter scan, no heuristics.
// Per-record failures are written as {"question_id":…,"hypothesis":null,"error":…}
// and counted in the output header.

// MARK: - Reader prompt builder

/// Builds the reader prompt for lme-spec answer-batch.
///
/// Presents the retrieved memory texts to the reader model, followed by the
/// question, and asks for a direct prose answer. Optional extra context strings
/// are appended after the memories when present, labelled so the reader can
/// distinguish them from the raw memory body.
///
/// - Parameters:
///   - question: The question text from the dataset.
///   - memoryTexts: Hydrated memory body texts from the estate.
/// - Returns: The prompt string to send to the reader model.
func lmeSpecReaderPrompt(question: String, memoryTexts: [String]) -> String {
    var parts: [String] = []
    parts.append("You are answering a question based on retrieved memory records.")
    parts.append("Read all records carefully and give a direct, concise answer.")
    parts.append("If the records do not contain the answer, say \"I don't know.\"")
    parts.append("")

    if memoryTexts.isEmpty {
        parts.append("No memory records were retrieved for this question.")
    } else {
        parts.append("Retrieved memory records:")
        parts.append("")
        for (i, text) in memoryTexts.enumerated() {
            parts.append("\(i + 1). \(text)")
        }
    }

    parts.append("")
    parts.append("Question: \(question)")
    parts.append("")
    parts.append("Answer:")
    return parts.joined(separator: "\n")
}

// MARK: - answer-batch consumer

/// Reads a lme-spec answer-input JSONL dump, runs the reader model for each
/// question, builds the §2 anscheck prompt from the reader's answer, and writes
/// judge_ready JSONL lines to the output path.
///
/// Answer-input dump format (written by lme-spec --dump-answer-inputs):
///   Line 0: header {"type":"header","benchmark":"lme-spec",…}
///   Lines 1…N: {"type":"answer_input","question_id":…,"memory_texts":[…],…}
///
/// Judge_ready output format (consumed by judge-sessions.py):
///   Line 0: header {"type":"header","benchmark":"lme-spec",…}
///   Lines 1…N: {"type":"judge_ready","question_id":…,"hypothesis":…,"anscheck_prompt":…}
///
/// Per-record failures (answer command failed or returned empty) are written as:
///   {"question_id":…,"hypothesis":null,"error":…}
///
/// - Parameters:
///   - inputsPath: Path to the lme-spec answer-input dump JSONL.
///   - answerCmd: Shell command for the reader model. Reads the prompt on stdin;
///     writes the answer on stdout (exit 0). The same subprocess seam as
///     `lmeRunJudge` in LongMemEvalJudge.swift.
///   - outputPath: Path to write the judge_ready JSONL output. Created with
///     owner-only permissions (0o600); must not already exist.
///   - judgeModel: Model identifier for the anscheck_prompt field (default matches
///     the official LongMemEval leaderboard model).
/// - Throws: MCPError when the input cannot be read or the output cannot be created.
public func runLMESpecAnswerBatch(
    inputsPath: String,
    answerCmd: String,
    outputPath: String,
    judgeModel: String = "gpt-4o-2024-08-06",
    limit: Int? = nil,
    offset: Int = 0
) throws {
    guard offset >= 0 else {
        throw MCPError(description: "lme-spec answer-batch: offset must be non-negative")
    }
    guard let rawData = FileManager.default.contents(atPath: inputsPath),
          let content = String(data: rawData, encoding: .utf8) else {
        throw MCPError(description: "lme-spec answer-batch: cannot read input dump '\(inputsPath)'")
    }

    let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
    guard !lines.isEmpty else {
        throw MCPError(description: "lme-spec answer-batch: input dump is empty: '\(inputsPath)'")
    }

    // Validate and parse the header line.
    guard let headerData = lines[0].data(using: .utf8),
          let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
          let headerType = header["type"] as? String, headerType == "header",
          let benchmark = header["benchmark"] as? String, benchmark == "lme-spec" else {
        throw MCPError(description:
            "lme-spec answer-batch: first line must be a header with benchmark=lme-spec in '\(inputsPath)'")
    }

    // Compute the selected-input digest over all answer_input lines in the dump.
    // Embedded in the output header for resume validation.
    let answerInputLines = lines.dropFirst().filter { line in
        guard let d = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let t = obj["type"] as? String else { return false }
        return t == "answer_input"
    }
    let selectedInputText = answerInputLines.joined(separator: "\n") + "\n"
    let selectedInputSHA256 = sha256HexOfString(selectedInputText)

    // Resume: collect question_ids already answered in the output file. Records
    // with a non-null hypothesis were written by a previous run; re-running the
    // reader for them wastes time and risks replacing a good answer.
    var resumedIDs = Set<String>()
    let outputExists = FileManager.default.fileExists(atPath: outputPath)

    if outputExists {
        // Validate ownership: regular file, owned by caller, mode 0600.
        var st = stat()
        guard lstat(outputPath, &st) == 0 else {
            throw MCPError(description: "lme-spec answer-batch: cannot stat output '\(outputPath)'")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw MCPError(description: "lme-spec answer-batch: output '\(outputPath)' is not a regular file")
        }
        guard (st.st_mode & 0o777) == 0o600 else {
            throw MCPError(description:
                "lme-spec answer-batch: output '\(outputPath)' has unexpected permissions; expected 0600")
        }
        guard st.st_uid == getuid() else {
            throw MCPError(description:
                "lme-spec answer-batch: output '\(outputPath)' is not owned by the current user")
        }
        // Validate digest and reader identity from the stored output header.
        if let existingData = FileManager.default.contents(atPath: outputPath),
           let existingText = String(data: existingData, encoding: .utf8),
           let firstLine = existingText.components(separatedBy: "\n").first(where: { !$0.isEmpty }),
           let fd = firstLine.data(using: .utf8),
           let fobj = try? JSONSerialization.jsonObject(with: fd) as? [String: Any] {
            if let storedDigest = fobj["selected_input_sha256"] as? String,
               !storedDigest.isEmpty, storedDigest != selectedInputSHA256 {
                throw MCPError(description:
                    "lme-spec answer-batch: output '\(outputPath)' digest mismatch; "
                    + "delete the output file to start a new run")
            }
            if let storedIdentity = fobj["reader_identity"] as? String,
               !storedIdentity.isEmpty, storedIdentity != "sha256:" + sha256HexOfString(answerCmd) {
                throw MCPError(description:
                    "lme-spec answer-batch: output '\(outputPath)' reader identity mismatch; "
                    + "delete the output file to start a new run")
            }
        }
        if let existingData = FileManager.default.contents(atPath: outputPath),
           let existingText = String(data: existingData, encoding: .utf8) {
            for existing in existingText.components(separatedBy: "\n") where !existing.isEmpty {
                guard let ed = existing.data(using: .utf8),
                      let eo = try? JSONSerialization.jsonObject(with: ed) as? [String: Any],
                      let eqid = eo["question_id"] as? String,
                      !(eo["hypothesis"] is NSNull) && eo["hypothesis"] != nil else { continue }
                resumedIDs.insert(eqid)
            }
        }
    }

    // Open the output file. When creating fresh, use O_EXCL for exclusive create:
    // atomic, no truncation of an existing file, no symlink following.
    // On resume (outputExists), open the existing file for append.
    let appendFd: Int32
    if !outputExists {
        appendFd = open(outputPath, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
    } else {
        appendFd = open(outputPath, O_WRONLY | O_APPEND, mode_t(0o600))
    }
    guard appendFd >= 0 else {
        let err = errno
        throw MCPError(description:
            "lme-spec answer-batch: cannot open output for append '\(outputPath)': "
                + String(cString: strerror(err)))
    }
    let outFH = FileHandle(fileDescriptor: appendFd, closeOnDealloc: true)
    defer { outFH.closeFile() }

    // Write the output header on a fresh file; skip it on resume (header already present).
    if !outputExists {
        var outHeader = header
        outHeader["judge_model"] = judgeModel
        // Embed selected-input digest and reader identity for resume validation.
        outHeader["selected_input_sha256"] = selectedInputSHA256
        // Commands may contain credentials. Persist only an opaque resume key.
        outHeader["reader_identity"] = "sha256:" + sha256HexOfString(answerCmd)
        if let hData = try? JSONSerialization.data(withJSONObject: outHeader, options: [.sortedKeys]),
           let hStr = String(data: hData, encoding: .utf8) {
            outFH.write(Data((hStr + "\n").utf8))
        }
    }

    var failureCount = 0

    var answerLines = Array(lines.dropFirst().dropFirst(offset))
    if let limit { answerLines = Array(answerLines.prefix(limit)) }

    for line in answerLines {
        guard let lineData = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let lineType = obj["type"] as? String, lineType == "answer_input",
              let questionID = obj["question_id"] as? String,
              let questionType = obj["question_type"] as? String,
              let question = obj["question"] as? String,
              let correctAnswer = obj["correct_answer"] as? String else {
            continue
        }

        // Resume: skip records already answered in a prior run.
        if resumedIDs.contains(questionID) { continue }

        let baseQuestionType = obj["base_question_type"] as? String ?? questionType
        let isAbstention = obj["is_abstention"] as? Bool ?? questionID.contains("_abs")
        let memoryTexts = obj["memory_texts"] as? [String] ?? []
        // Build the reader prompt from the retrieved memory texts.
        let prompt = lmeSpecReaderPrompt(
            question: question,
            memoryTexts: memoryTexts)

        // Run the reader model subprocess (same seam as lmeRunJudge).
        let readerAnswer: String
        do {
            readerAnswer = try lmeRunJudge(cmd: answerCmd, prompt: prompt)
        } catch {
            FileHandle.standardError.write(Data(
                "[lme-spec answer-batch] reader cmd failed for \(questionID): \(error)\n".utf8))
            failureCount += 1
            let failObj: [String: Any] = [
                "question_id": questionID,
                "hypothesis": NSNull(),
                "error": "\(error)",
            ]
            if let fd = try? JSONSerialization.data(withJSONObject: failObj, options: [.sortedKeys]),
               let fs = String(data: fd, encoding: .utf8) {
                outFH.write(Data((fs + "\n").utf8))
            }
            continue
        }

        // Build the §2 anscheck prompt from the reader's answer. Uses the existing
        // per-type builder so judge-sessions.py grades it unchanged.
        let anscheckPromptStr: String
        do {
            anscheckPromptStr = try anscheckPrompt(
                questionType: isAbstention ? baseQuestionType + "_abs" : baseQuestionType,
                questionID: questionID,
                question: question,
                answer: correctAnswer,
                hypothesis: readerAnswer)
        } catch {
            // Unknown question type — log and write a failure line.
            FileHandle.standardError.write(Data(
                "[lme-spec answer-batch] anscheck prompt failed for \(questionID): \(error)\n".utf8))
            failureCount += 1
            let failObj: [String: Any] = [
                "question_id": questionID,
                "hypothesis": NSNull(),
                "error": "\(error)",
            ]
            if let fd = try? JSONSerialization.data(withJSONObject: failObj, options: [.sortedKeys]),
               let fs = String(data: fd, encoding: .utf8) {
                outFH.write(Data((fs + "\n").utf8))
            }
            continue
        }

        // Write the judge_ready line. The anscheck_prompt is the filled §2 prompt;
        // hypothesis is the reader model's raw answer text.
        let judgeReadyObj: [String: Any] = [
            "type": "judge_ready",
            "question_id": questionID,
            "base_question_type": baseQuestionType,
            "is_abstention": isAbstention,
            "hypothesis": readerAnswer,
            "anscheck_prompt": anscheckPromptStr,
            "model": judgeModel,
            "n": 1,
            "temperature": 0,
            "max_tokens": 10,
        ]
        if let jd = try? JSONSerialization.data(withJSONObject: judgeReadyObj, options: [.sortedKeys]),
           let js = String(data: jd, encoding: .utf8) {
            outFH.write(Data((js + "\n").utf8))
        }
    }

    if failureCount > 0 {
        FileHandle.standardError.write(Data(
            "[lme-spec answer-batch] \(failureCount) record(s) failed — see error lines in output\n".utf8))
    }
}
