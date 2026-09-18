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
    Answer the following question using the provided context. The context is \
    prior conversation with the user.

    You may INFER the answer from what the user said — including their stated \
    preferences, interests, and habits. The answer does NOT need to appear \
    verbatim in the context. Only respond "I don't know" when the context is \
    genuinely unrelated to the question.

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
/// Delegates to `runBoundedCmdSubprocess` — the one subprocess seam shared
/// with the reranker — so every stage of the child's lifecycle (exit wait,
/// TERM→KILL escalation, post-exit pipe drains) is bounded. The judge
/// process must exit 0; a non-zero exit throws `MCPError`, and a timeout
/// (any bound firing) throws rather than hanging the run.
///
/// - Parameters:
///   - cmd: Shell command string (e.g. `"claude -p"` or `"./judge.sh"`).
///   - prompt: The prompt text to write to the command's stdin.
/// - Returns: Trimmed stdout from the judge process.
/// - Throws: `MCPError` on launch failure, timeout, or non-zero exit status.
func lmeRunJudge(cmd: String, prompt: String) throws -> String {
    guard let result = try runBoundedCmdSubprocess(cmd: cmd, prompt: prompt) else {
        throw MCPError(description:
            "judge command timed out after \(Int(subprocessTimeoutSeconds))s")
    }

    guard result.terminationStatus == 0 else {
        let errText = String(data: result.stderr, encoding: .utf8) ?? ""
        let errSuffix = errText.isEmpty ? "" : ": \(errText.prefix(200))"
        throw MCPError(description:
            "judge command exited \(result.terminationStatus)\(errSuffix)")
    }

    let output = String(data: result.stdout, encoding: .utf8) ?? ""
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

// MARK: - Verdict grading (published-protocol parity)

/// How a judge answer is graded against the dataset's gold answer.
///
/// The two modes are NOT interchangeable and a run must record which it
/// used — they answer different questions and produce different numbers on
/// identical answers.
enum LMEJudgeGrading: String, Sendable {
    /// Deterministic normalized-substring containment. No second model call,
    /// no non-determinism, but it under-counts every semantically-correct
    /// paraphrase ("in 1997" vs gold "1997" passes; "he was nineteen" vs
    /// gold "19" does not).
    case substring
    /// A second model call returns a correctness verdict for the candidate
    /// answer given the gold answer. This is the protocol published
    /// leaderboard numbers are produced under, so it is the mode to use when
    /// a cell is meant to sit beside one. Costs one extra judge call per
    /// question and inherits the judge model's own error rate.
    case verdict
}

/// Formats the verdict-step prompt: given the question, the gold answer, and
/// a candidate answer, ask for a single-word correctness verdict.
///
/// Deliberately narrow: the judge is told to grade semantic equivalence of
/// the ANSWER, not to re-answer the question, and to emit one token. The
/// wording is stable — changing it changes the meaning of stored verdicts.
func lmeVerdictPrompt(question: String, goldAnswer: String,
                      candidateAnswer: String) -> String {
    """
    You are grading a single answer for correctness.

    Reply with exactly one word and nothing else: CORRECT or INCORRECT. \
    Do not explain, do not restate the question, do not qualify the verdict.

    The candidate answer is CORRECT when it conveys the same fact as the \
    reference answer — wording, length, and extra context do not matter. \
    It is INCORRECT when it states a different fact, contradicts the \
    reference, or declines to answer.

    Question: \(question)

    Reference answer: \(goldAnswer)

    Candidate answer: \(candidateAnswer)

    Verdict:
    """
}

/// Parses a verdict-step reply into a correctness decision.
///
/// The verdict is read POSITIONALLY, from one of the two slots the prompt
/// actually defines. Nothing else in the reply is consulted:
///
///   1. The first token of the reply — `lmeVerdictPrompt` asks for exactly
///      one word and nothing else, so that word is the verdict.
///   2. Failing that, the first token after the LAST colon — the prompt ends
///      with a bare `Verdict:` label, so a judge that echoes the label is an
///      expected shape ("Verdict: CORRECT", "The verdict is: INCORRECT").
///
/// Anything else is a judge failure and returns nil, so the caller falls back
/// to substring grading rather than scoring a reply it could not read.
///
/// Why not search the reply for the word: "not correct" CONTAINS "CORRECT",
/// so a substring scan graded every negated reply as correct and inflated
/// answer accuracy. Position is the fix.
///
/// Sentiment is deliberately not interpreted. A negation blocklist ("contains
/// 'not' → false") fails on "not incorrect" and on every phrasing nobody
/// enumerated, so it is not used: under this contract "not incorrect" is
/// simply unparseable — a verdict that is not in its slot is absent, not a
/// double negative to be resolved.
func lmeParseVerdict(_ reply: String) -> Bool? {
    // Slot 1: the reply itself is the verdict word.
    if let verdict = lmeVerdictToken(reply) { return verdict }
    // Slot 2: the judge echoed the prompt's label ahead of the verdict.
    guard let lastColon = reply.lastIndex(of: ":") else { return nil }
    return lmeVerdictToken(String(reply[reply.index(after: lastColon)...]))
}

/// Matches the FIRST whitespace-delimited token of `text` against the two
/// verdict words, exactly.
///
/// Leading and trailing non-letters are discarded so markdown emphasis and
/// trailing punctuation do not defeat the match ("**CORRECT**", "INCORRECT,"
/// and "CORRECT." all read as the bare word). The comparison is otherwise
/// exact, which is what keeps "not" from ever matching "CORRECT".
private func lmeVerdictToken(_ text: String) -> Bool? {
    guard let raw = text.split(whereSeparator: \.isWhitespace).first else { return nil }
    let token = String(raw.drop(while: { !$0.isLetter })
                          .prefix(while: \.isLetter)).uppercased()
    switch token {
    case "CORRECT":   return true
    case "INCORRECT": return false
    default:          return nil
    }
}
