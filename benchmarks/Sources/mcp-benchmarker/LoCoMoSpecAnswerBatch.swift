import Darwin
import Foundation

// Offline reader seam for LoCoMo. Retrieval and hydration happen once in the
// frozen spec lane; arbitrary local readers then consume the immutable JSONL
// and are scored mechanically by the existing official token-F1 scorer.

func loCoMoSpecReaderPrompt(
    question: String,
    category: Int,
    memoryTexts: [String]
) -> String {
    var lines = [
        "Answer the question using only the retrieved memory records.",
        "Give only a short direct answer, without explanation.",
    ]
    if category == 5 {
        lines.append("If the records do not contain the answer, reply exactly: No information available.")
    } else {
        lines.append("If the records do not contain the answer, reply: I don't know.")
    }
    lines.append("")
    lines.append("Retrieved memory records:")
    if memoryTexts.isEmpty {
        lines.append("(none)")
    } else {
        for (index, memory) in memoryTexts.enumerated() {
            lines.append("[\(index + 1)] \(memory)")
        }
    }
    lines.append("")
    lines.append("Question: \(question)")
    lines.append("Answer:")
    return lines.joined(separator: "\n")
}

private struct ValidatedLoCoMoAnswerInput {
    let rawLine: String
    let row: [String: Any]
    let questionID: String
    let category: Int
    let question: String
    let gold: String
    let memoryTexts: [String]
}

private func loCoMoStringArray(
    _ row: [String: Any], key: String, lineNumber: Int
) throws -> [String] {
    guard let values = row[key] as? [Any], values.allSatisfy({ $0 is String }) else {
        throw MCPError(description:
            "locomo-spec answer-batch: line \(lineNumber) field '\(key)' must be an array of strings")
    }
    return values.map { $0 as! String }
}

private func validateLoCoMoAnswerInput(
    rawLine: String, lineNumber: Int
) throws -> ValidatedLoCoMoAnswerInput {
    guard let data = rawLine.data(using: .utf8) else {
        throw MCPError(description:
            "locomo-spec answer-batch: line \(lineNumber) is not UTF-8")
    }
    let object: Any
    do {
        object = try JSONSerialization.jsonObject(with: data)
    } catch {
        throw MCPError(description:
            "locomo-spec answer-batch: line \(lineNumber) is malformed JSON: \(error)")
    }
    guard let row = object as? [String: Any] else {
        throw MCPError(description:
            "locomo-spec answer-batch: line \(lineNumber) must be a JSON object")
    }
    guard row["type"] as? String == "answer_input" else {
        throw MCPError(description:
            "locomo-spec answer-batch: line \(lineNumber) has wrong kind; expected type=answer_input")
    }
    guard row["benchmark"] as? String == "locomo-spec" else {
        throw MCPError(description:
            "locomo-spec answer-batch: line \(lineNumber) field 'benchmark' must be locomo-spec")
    }
    guard let questionID = row["question_id"] as? String, !questionID.isEmpty else {
        throw MCPError(description:
            "locomo-spec answer-batch: line \(lineNumber) is missing non-empty string field 'question_id'")
    }
    guard let category = row["category"] as? Int, (1...5).contains(category) else {
        throw MCPError(description:
            "locomo-spec answer-batch: line \(lineNumber) field 'category' must be an integer from 1 through 5")
    }
    guard let categoryLabel = row["category_label"] as? String, !categoryLabel.isEmpty else {
        throw MCPError(description:
            "locomo-spec answer-batch: line \(lineNumber) is missing non-empty string field 'category_label'")
    }
    _ = categoryLabel
    guard let question = row["question"] as? String, !question.isEmpty else {
        throw MCPError(description:
            "locomo-spec answer-batch: line \(lineNumber) is missing non-empty string field 'question'")
    }
    guard row.keys.contains("gold_answer") else {
        throw MCPError(description:
            "locomo-spec answer-batch: line \(lineNumber) is missing field 'gold_answer'")
    }
    let gold: String
    if let value = row["gold_answer"] as? String {
        gold = value
    } else if row["gold_answer"] is NSNull, category == 5 {
        gold = ""
    } else {
        throw MCPError(description:
            "locomo-spec answer-batch: line \(lineNumber) field 'gold_answer' must be a string (or null for category 5)")
    }
    let memoryTexts = try loCoMoStringArray(row, key: "memory_texts", lineNumber: lineNumber)
    let drawerIDs = try loCoMoStringArray(
        row, key: "retrieved_drawer_ids", lineNumber: lineNumber)
    _ = try loCoMoStringArray(row, key: "retrieved_dia_ids", lineNumber: lineNumber)
    guard drawerIDs.count == memoryTexts.count else {
        throw MCPError(description:
            "locomo-spec answer-batch: line \(lineNumber) memory_texts and retrieved_drawer_ids counts differ")
    }
    guard let rawRanks = row["retrieved_ranks"] as? [Any],
          rawRanks.count == memoryTexts.count else {
        throw MCPError(description:
            "locomo-spec answer-batch: line \(lineNumber) retrieved_ranks must contain the one-based source rank of every memory_text")
    }
    let ranks = rawRanks.compactMap { $0 as? Int }
    guard ranks.count == rawRanks.count,
          ranks.allSatisfy({ $0 > 0 }),
          zip(ranks, ranks.dropFirst()).allSatisfy({ $0 < $1 }) else {
        throw MCPError(description:
            "locomo-spec answer-batch: line \(lineNumber) retrieved_ranks must be positive and strictly increasing")
    }
    return ValidatedLoCoMoAnswerInput(
        rawLine: rawLine, row: row, questionID: questionID,
        category: category, question: question, gold: gold,
        memoryTexts: memoryTexts)
}

// Encode one answer_score object to a JSON line with sorted keys.
// Used for both the progress file and the final output; same bytes in both.
private func encodeAnswerScoreRow(_ object: [String: Any]) throws -> String {
    let encoded = try JSONSerialization.data(
        withJSONObject: object, options: [.sortedKeys])
    return String(decoding: encoded, as: UTF8.self)
}

// Load already-scored rows from the progress file, validating the progress
// header against the current invocation's digest and reader identity.
// The first non-empty line must be the progress header; remaining lines are data rows.
private func loadProgressFile(
    at path: String,
    selectedIDs: Set<String>,
    expectedDigest: String,
    expectedIdentity: String
) throws -> [String: [String: Any]] {
    guard let data = FileManager.default.contents(atPath: path),
          let content = String(data: data, encoding: .utf8) else {
        throw MCPError(description:
            "locomo-spec answer-batch: cannot read progress file '\(path)'")
    }
    var result: [String: [String: Any]] = [:]
    let lines = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    for (index, line) in lines.enumerated() {
        guard let lineData = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else {
            throw MCPError(description:
                "locomo-spec answer-batch: progress file '\(path)' line \(index + 1) is malformed JSON")
        }
        // First line must be the progress header.
        if index == 0 {
            guard obj["type"] as? String == "progress_header" else {
                throw MCPError(description:
                    "locomo-spec answer-batch: progress file '\(path)' first line must be a progress_header")
            }
            if let storedDigest = obj["selected_input_sha256"] as? String,
               !storedDigest.isEmpty, storedDigest != expectedDigest {
                throw MCPError(description:
                    "locomo-spec answer-batch: progress file '\(path)' digest mismatch; "
                    + "delete the progress file to start a new run")
            }
            if let storedIdentity = obj["reader_identity"] as? String,
               !storedIdentity.isEmpty, storedIdentity != expectedIdentity {
                throw MCPError(description:
                    "locomo-spec answer-batch: progress file '\(path)' reader identity mismatch; "
                    + "delete the progress file to start a new run")
            }
            continue
        }
        guard let qid = obj["question_id"] as? String, !qid.isEmpty else {
            throw MCPError(description:
                "locomo-spec answer-batch: progress file '\(path)' line \(index + 1) missing question_id")
        }
        // Skip rows whose question_id is not in the current selected set.
        guard selectedIDs.contains(qid) else { continue }
        result[qid] = obj
    }
    return result
}

func runLoCoMoSpecAnswerBatch(
    inputsPath: String,
    answerCmd: String,
    outputPath: String,
    limit: Int? = nil,
    offset: Int = 0,
    readerModel: String = "unknown"
) throws {
    guard offset >= 0 else {
        throw MCPError(description: "locomo-spec answer-batch: offset must be non-negative")
    }
    guard let data = FileManager.default.contents(atPath: inputsPath),
          let content = String(data: data, encoding: .utf8) else {
        throw MCPError(description:
            "locomo-spec answer-batch: cannot read input dump '\(inputsPath)'")
    }
    var lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
    if lines.last == "" { lines.removeLast() } // accept one ordinary terminal newline
    guard let first = lines.first,
          let headerData = first.data(using: .utf8),
          let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
          header["type"] as? String == "header",
          header["benchmark"] as? String == "locomo-spec" else {
        throw MCPError(description:
            "locomo-spec answer-batch: first line must be a locomo-spec header")
    }

    var inputObjects: [ValidatedLoCoMoAnswerInput] = []
    var questionIDs = Set<String>()
    for (index, line) in lines.dropFirst().enumerated() {
        let input = try validateLoCoMoAnswerInput(
            rawLine: line, lineNumber: index + 2)
        guard questionIDs.insert(input.questionID).inserted else {
            throw MCPError(description:
                "locomo-spec answer-batch: duplicate question_id '\(input.questionID)' on line \(index + 2)")
        }
        inputObjects.append(input)
    }

    let selectedObjects: [ValidatedLoCoMoAnswerInput]
    let afterOffset = inputObjects.dropFirst(offset)
    if let limit {
        selectedObjects = Array(afterOffset.prefix(limit))
    } else {
        selectedObjects = Array(afterOffset)
    }

    guard !selectedObjects.isEmpty else {
        throw MCPError(description:
            "locomo-spec answer-batch: offset/limit selected zero input rows")
    }
    let selectedInputBytes = selectedObjects.map(\.rawLine).joined(separator: "\n") + "\n"
    let selectedInputSHA256 = sha256HexOfString(selectedInputBytes)

    // Refuse if the final output already exists (no-clobber, identical to original behaviour).
    let outputURL = URL(fileURLWithPath: outputPath)
    if FileManager.default.fileExists(atPath: outputPath) {
        throw MCPError(description:
            "record already exists and records are never overwritten: \(outputPath) "
            + "— a second run of this arm in one pass must carry its own serial")
    }

    // Progress file: <outputPath>.partial.jsonl, opened append, mode 0600.
    // Rows are appended here after every reader call so that a crash can be resumed.
    let progressPath = outputPath + ".partial.jsonl"
    let selectedIDSet = Set(selectedObjects.map(\.questionID))

    // Resume: if a progress file exists, validate ownership and header, then load rows.
    let progressExists = FileManager.default.fileExists(atPath: progressPath)
    var resumedRows: [String: [String: Any]] = [:]
    if progressExists {
        // Validate: regular file, owned by caller, mode 0600.
        var st = stat()
        guard lstat(progressPath, &st) == 0 else {
            throw MCPError(description: "locomo-spec answer-batch: cannot stat progress file '\(progressPath)'")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw MCPError(description: "locomo-spec answer-batch: progress file '\(progressPath)' is not a regular file")
        }
        guard (st.st_mode & 0o777) == 0o600 else {
            throw MCPError(description:
                "locomo-spec answer-batch: progress file '\(progressPath)' has unexpected permissions; expected 0600")
        }
        guard st.st_uid == getuid() else {
            throw MCPError(description:
                "locomo-spec answer-batch: progress file '\(progressPath)' is not owned by the current user")
        }
        resumedRows = try loadProgressFile(
            at: progressPath,
            selectedIDs: selectedIDSet,
            expectedDigest: selectedInputSHA256,
            expectedIdentity: readerModel)
    }
    // Only rows that will actually be reused count as resumed; rows that recorded
    // a reader failure are asked again below and do not count.
    let resumedCount = resumedRows.values.filter { $0["error"] == nil }.count

    // Open the progress file for appending (create exclusively if absent, mode 0600).
    // O_EXCL on the fresh path prevents truncation of an existing file and symlink following.
    let progressFd: Int32
    if progressExists {
        progressFd = open(progressPath, O_WRONLY | O_APPEND, mode_t(0o600))
    } else {
        progressFd = open(progressPath, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
    }
    guard progressFd >= 0 else {
        let err = errno
        throw MCPError(description:
            "locomo-spec answer-batch: cannot open progress file '\(progressPath)': "
            + String(cString: strerror(err)))
    }
    defer { close(progressFd) }

    // On a fresh progress file, write the progress header so a resume invocation
    // can confirm it is continuing the same selected-input set and reader command.
    if !progressExists {
        let headerObj: [String: Any] = [
            "type": "progress_header",
            "selected_input_sha256": selectedInputSHA256,
            "reader_identity": readerModel,
        ]
        if let headerData = try? JSONSerialization.data(withJSONObject: headerObj, options: [.sortedKeys]),
           let headerStr = String(data: headerData, encoding: .utf8) {
            let headerLine = Array((headerStr + "\n").utf8)
            _ = headerLine.withUnsafeBytes { raw in write(progressFd, raw.baseAddress!, raw.count) }
        }
    }

    // Score each selected row, reusing resumed rows or calling the reader.
    var scoredByID: [String: [String: Any]] = [:]
    var failures = 0
    for (done, input) in selectedObjects.enumerated() {
        let questionID = input.questionID

        // Reuse a scored row from the progress file; a row that recorded a reader
        // failure (`error` present, prediction null) is asked again, so a transient
        // reader outage is never baked into the final file by a resume.
        if let existing = resumedRows[questionID], existing["error"] == nil {
            scoredByID[questionID] = existing
            // Progress line for resumed rows (stderr) so the operator sees continuity.
            let progressLine = "[locomo answer-batch] \(done + 1)/\(selectedObjects.count) \(questionID)\n"
            FileHandle.standardError.write(Data(progressLine.utf8))
            continue
        }

        // Call the reader for this row.
        let row = input.row
        let category = input.category
        let question = input.question
        let gold = input.gold
        let memories = input.memoryTexts
        let prompt = loCoMoSpecReaderPrompt(
            question: question, category: category, memoryTexts: memories)

        let scoredRow: [String: Any]
        do {
            let prediction = try lmeRunJudge(cmd: answerCmd, prompt: prompt)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let score = try scoreQuestion(
                category: category, prediction: prediction, goldAnswer: gold)
            scoredRow = [
                "type": "answer_score",
                "question_id": questionID,
                "category": category,
                "gold_answer": row["gold_answer"] ?? NSNull(),
                "prediction": prediction,
                "score": score,
                "retrieved_drawer_ids": row["retrieved_drawer_ids"] ?? [],
                "retrieved_dia_ids": row["retrieved_dia_ids"] ?? [],
                "retrieved_ranks": row["retrieved_ranks"] ?? [],
            ]
        } catch {
            failures += 1
            scoredRow = [
                "type": "answer_score",
                "question_id": questionID,
                "category": category,
                "gold_answer": row["gold_answer"] ?? NSNull(),
                "prediction": NSNull(),
                "score": 0.0,
                "error": "\(error)",
                "retrieved_drawer_ids": row["retrieved_drawer_ids"] ?? [],
                "retrieved_dia_ids": row["retrieved_dia_ids"] ?? [],
                "retrieved_ranks": row["retrieved_ranks"] ?? [],
            ]
        }

        // Append to progress file and flush immediately so a crash loses at most this row.
        let jsonLine = (try encodeAnswerScoreRow(scoredRow)) + "\n"
        let lineData = Data(jsonLine.utf8)
        lineData.withUnsafeBytes { ptr in
            _ = write(progressFd, ptr.baseAddress!, ptr.count)
        }
        // fsync so the bytes reach the disk before we move to the next row.
        fsync(progressFd)

        scoredByID[questionID] = scoredRow

        // One stderr progress line per row: [locomo answer-batch] <done>/<selected> <question_id>
        let progressLine = "[locomo answer-batch] \(done + 1)/\(selectedObjects.count) \(questionID)\n"
        FileHandle.standardError.write(Data(progressLine.utf8))
    }

    // Assemble the final output in input order (not append order).
    // Compute the aggregate over the scored rows in that same order.
    var scoredRows: [[String: Any]] = []
    var scoreTuples: [(category: Int, score: Double, evidenceRecall: Double)] = []
    for input in selectedObjects {
        let scoredRow = scoredByID[input.questionID]!
        scoredRows.append(scoredRow)
        let score = scoredRow["score"] as? Double ?? 0.0
        scoreTuples.append((input.category, score, 0.0))
    }

    // Re-count failures from the assembled rows (resumed rows may carry a failure too).
    failures = scoredRows.filter { $0["error"] != nil }.count

    let aggregate = loCoMoSpecAggregate(scores: scoreTuples)

    // When every selected row failed, leave the progress file intact for the next resume
    // attempt and surface the error without writing a final file.
    if !scoredRows.isEmpty, failures == scoredRows.count {
        throw MCPError(description:
            "locomo-spec answer-batch: all \(failures) records failed")
    }

    var outputHeader = header
    outputHeader["type"] = "answer_score_header"
    outputHeader["reader_command_recorded"] = false
    outputHeader["reader_model"] = readerModel
    outputHeader["offset"] = offset
    outputHeader["input_row_count"] = inputObjects.count
    outputHeader["selected_input_count"] = selectedObjects.count
    outputHeader["selected_input_sha256"] = selectedInputSHA256
    outputHeader["questions"] = scoredRows.count
    outputHeader["failures"] = failures
    outputHeader["overall_token_f1"] = aggregate.overall
    outputHeader["by_category"] = aggregate.byCategory.map { metric in
        [
            "category": metric.category,
            "score": metric.accuracy,
            "question_count": metric.questionCount,
        ]
    }
    // Two additive fields that change the header bytes relative to a pre-stream run.
    // resumed_row_count is 0 on a clean run.  progress_file records the path for provenance.
    outputHeader["resumed_row_count"] = resumedCount
    outputHeader["progress_file"] = progressPath

    let objects = [outputHeader] + scoredRows
    let rendered = try objects.map { object -> String in
        let encoded = try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys])
        return String(decoding: encoded, as: UTF8.self)
    }.joined(separator: "\n") + "\n"
    try writeRecordNeverOverwrite(
        Data(rendered.utf8),
        to: outputURL,
        permissions: 0o600)

    // Remove the progress file now that the final file is safely written.
    try? FileManager.default.removeItem(atPath: progressPath)

    FileHandle.standardOutput.write(Data((
        "answer-batch: records=\(scoredRows.count) failed=\(failures) "
        + "benchmark=locomo-spec token_f1="
        + String(format: "%.4f", aggregate.overall)
        + " out=\(outputPath)\n").utf8))
}
