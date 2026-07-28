import Foundation

// LongMemEvalJudge.swift — Thin subprocess judge for LME-03 judge mode.
//
// The judge hook is generic: any command that reads a prompt on stdin and
// writes its answer on stdout qualifies. Examples:
//   --judge-cmd "claude -p"
//   --judge-cmd "ollama run llama3 -"
//   --judge-cmd "./my-judge.sh"
//
// Design constraints (per mission):
//   - No vendor AI SDK in the repo. The judge is an external command the
//     operator supplies. This preserves the BYOAI posture.
//   - Command executed via `/bin/sh -c <cmd>` so shell features (pipes,
//     env vars, quoted args) all work.
//   - Grading is deterministic normalized-substring match of the judge
//     answer against the dataset's gold `answer`, the same primitive used
//     by the evidence-density scorer.
//   - judge mode is off by default; pass `--judge-cmd` to enable. A run
//     without a judge command records SKIPPED in the report.
//
// Process safety note:
//   `lmeRunJudge` calls `Process.waitUntilExit()`, which blocks the calling
//   thread. This is intentional for a sequential benchmark harness — judge
//   calls are serialized per question and the tool is a CLI, not a server.
//   Callers from async contexts (`runLMEQuestions`) accept this behaviour.

// MARK: - Prompt formatting

/// Formats the stdin prompt sent to the judge subprocess.
///
/// The question and payload are embedded verbatim. The format is stable —
/// any change here changes the semantics of stored transcripts.
func lmeJudgePrompt(question: String, payload: String) -> String {
    """
    Answer the following question using ONLY the provided context. \
    If the answer is not found in the context, respond with "I don't know". \
    Keep your answer as concise as possible (a word, phrase, or short sentence).

    Question: \(question)

    Context:
    \(payload)

    Answer:
    """
}

// MARK: - Subprocess runner

/// Runs the judge command with `prompt` on stdin, returns the trimmed stdout.
///
/// The command is executed via `/bin/sh -c <cmd>` so shell features work.
/// The judge process must exit 0; a non-zero exit throws `MCPError`.
///
/// - Parameters:
///   - cmd: Shell command string (e.g. `"claude -p"` or `"./judge.sh"`).
///   - prompt: The prompt text to write to the command's stdin.
/// - Returns: Trimmed stdout from the judge process.
/// - Throws: `MCPError` on process launch failure or non-zero exit status.
func lmeRunJudge(cmd: String, prompt: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", cmd]

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()

    // Write the prompt to stdin, then close to signal EOF.
    let promptData = Data(prompt.utf8)
    stdinPipe.fileHandleForWriting.write(promptData)
    stdinPipe.fileHandleForWriting.closeFile()

    process.waitUntilExit()

    let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: outputData, encoding: .utf8) ?? ""

    guard process.terminationStatus == 0 else {
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: errData, encoding: .utf8) ?? ""
        let errSuffix = errText.isEmpty ? "" : ": \(errText.prefix(200))"
        throw MCPError(description:
            "judge command exited \(process.terminationStatus)\(errSuffix)")
    }

    return output.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Answer grader

/// Grades a judge answer against the dataset's gold answer.
///
/// Algorithm: normalize both strings (lowercase + collapse whitespace, via
/// `lmeNormalizeForEvidence`), then check if the normalized gold answer is
/// a substring of the normalized judge answer.
///
/// Returns false when either input is empty after normalization.
///
/// This reuses `lmeNormalizeForEvidence` (LongMemEvalTokenEfficiency.swift)
/// so the evidence-density scorer and the judge grader are on the same scale.
///
/// - Parameters:
///   - judgeAnswer: The text returned by the judge subprocess.
///   - goldAnswer: The dataset's reference answer.
/// - Returns: true when the normalized gold is a substring of the normalized
///   judge answer; false otherwise.
func lmeGradeJudgeAnswer(_ judgeAnswer: String, goldAnswer: String) -> Bool {
    let normJudge = lmeNormalizeForEvidence(judgeAnswer)
    let normGold = lmeNormalizeForEvidence(goldAnswer)
    guard !normGold.isEmpty, !normJudge.isEmpty else { return false }
    return normJudge.contains(normGold)
}
