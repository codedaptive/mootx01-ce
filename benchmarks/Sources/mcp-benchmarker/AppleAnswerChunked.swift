// AppleAnswerChunked.swift
//
// Pure (model-free) logic for apple-answer's chunked reader modes.
//
// Apple Foundation Models has an 8 192-token context window. A 10-hit
// lme-spec retrieval payload is ~23k tokens and is refused by the engine
// ("Content contains N tokens, which exceeds the maximum allowed context
// size of M"). The chunked reader splits the payload on memory boundaries
// so the engine can answer across multiple shorter rounds.
//
// Two reader recipes are defined here:
//
//   map-reduce  Split memories into round-budget chunks. Each chunk
//               produces a note ("what these memories say about the
//               question"). A final round combines all notes into the
//               answer. If the combined notes outgrow the round budget,
//               the notes are reduced pairwise (i.e. map-reduce is
//               applied recursively, one level only).
//
//   refine      Round 1 = question + chunk 1 → draft. Each subsequent
//               round = question + draft + next chunk → revised draft.
//               If the draft itself outgrows the round budget before all
//               chunks are exhausted, the current draft is emitted as the
//               final answer and the remaining chunks are skipped (reported
//               on stderr with "draft-overflow=true").
//
// These functions are intentionally free of FoundationModels imports so
// tests can exercise them without a model or macOS 26.
//
// The token-counting seam follows the same pattern as MemBenchSpecProtocol:
// load Cl100kTokenizer from MOOT_BENCH_CL100K when the artifact is present;
// fall back to a UTF-8-byte estimate when it is not.  The byte estimate errs
// conservatively (smaller chunks) so the engine never sees an over-budget chunk.

import Foundation

// MARK: - Reader mode

/// Reader strategy for the apple-answer subcommand.
///
/// - single:    The original behaviour: one call with the full prompt.
///              Exits non-zero with the engine's context-exceeded text when
///              the prompt is over --context-tokens.
/// - mapReduce: Splits memories into round-budget chunks, collects one note
///              per chunk, then combines notes into the final answer.
/// - refine:    Iterative draft: round 1 produces a draft from the first
///              chunk; subsequent rounds refine the draft with each next chunk.
public enum AppleAnswerMode: String, Sendable {
    case single      = "single"
    case mapReduce   = "map-reduce"
    case refine      = "refine"
    /// Two-round picker: round 1 selects records by header lines,
    /// round 2 answers using the picked records' full distilled bodies.
    case pick        = "pick"
}

// MARK: - Token counting seam

/// Lazy cl100k_base tokenizer loaded once from MOOT_BENCH_CL100K (same env var
/// as MemBenchSpecProtocol).  nil when the vocabulary artifact is absent.
private let _appleAnswerCl100k: Cl100kTokenizer? = {
    guard let path = ProcessInfo.processInfo.environment["MOOT_BENCH_CL100K"] else {
        return nil
    }
    return try? Cl100kTokenizer.load(from: path)
}()

/// Returns the cl100k_base token count for `text`.
///
/// When MOOT_BENCH_CL100K is set and loaded this is exact.  Otherwise falls
/// back to `ceil(utf8ByteCount / 4)` — a conservative estimate that errs on
/// the side of producing smaller chunks (safe: too-small = one extra round;
/// too-large = engine refusal, which is worse).
public func appleAnswerEstimateTokens(_ text: String) -> Int {
    if let tok = _appleAnswerCl100k { return tok.countTokens(text) }
    // UTF-8 bytes ÷ 4 rounded up. Typical English prose ≈ 3-4 bytes/token;
    // the ceiling keeps chunks inside the declared budget even for short tokens.
    return (text.utf8.count + 3) / 4
}

// MARK: - Prompt parsing

/// The parsed sections of a reader prompt split on its memory boundaries.
public struct ParsedReaderPrompt: Sendable {
    /// Everything before the first numbered memory line.
    public var header: String
    /// Each memory text, stripped of its "N. " prefix.
    public var memories: [String]
    /// Everything from the blank line after the last memory through "Answer:".
    public var footer: String
}

/// Attempts to parse a reader prompt produced by `lmeSpecReaderPrompt`.
///
/// The lme-spec layout is:
/// ```
/// <preamble lines>
/// Retrieved memory records:
///
/// 1. <first memory>
/// 2. <second memory>
/// …
///
/// Question: <text>
///
/// Answer:
/// ```
///
/// Returns nil when the layout is not recognised; the caller falls back to
/// single-shot and logs `layout=unknown` on stderr.
public func parseReaderPrompt(_ prompt: String) -> ParsedReaderPrompt? {
    let lines = prompt.components(separatedBy: "\n")

    // A memory record spans MANY lines: the numbered header line ("N. <uuid> ·
    // Session … · …"), then indented turn text, blank lines, and often a
    // numbered list of its own ("1. **Gitzo** …"). So a boundary is not "any
    // numbered line": it is a column-0 line whose number is the NEXT sequence
    // number, and, when the first record's body opens with a drawer UUID, whose
    // body opens with one too. The UUID guard is what keeps a record's inner
    // list item "2. …" from being read as record 2.
    func isRecordStart(_ line: String, expected: Int, requireUUID: Bool) -> Bool {
        guard !line.hasPrefix(" "), let body = extractNumberedMemoryText(line),
              leadingNumber(line) == expected else { return false }
        return requireUUID ? bodyOpensWithUUID(body) : true
    }

    // Find the first record line ("1. …") and learn whether records carry UUIDs.
    var firstIdx: Int? = nil
    for (i, line) in lines.enumerated() where isRecordStart(line, expected: 1, requireUUID: false) {
        firstIdx = i; break
    }
    guard let first = firstIdx, let firstBody = extractNumberedMemoryText(lines[first]) else { return nil }
    let requireUUID = bodyOpensWithUUID(firstBody)

    // Walk forward: each record runs until the next record start or the footer
    // marker ("Question:" at column 0). Everything before the first record is
    // the header; the footer starts at the marker.
    var memories: [String] = []
    var current: [String] = []
    var footerStart = lines.count
    var i = first
    while i < lines.count {
        let line = lines[i]
        if line.hasPrefix("Question:") {
            footerStart = i
            break
        }
        if isRecordStart(line, expected: memories.count + 1, requireUUID: requireUUID), !current.isEmpty || memories.isEmpty && i == first {
            if !current.isEmpty { memories.append(trimTrailingBlank(current).joined(separator: "\n")); current = [] }
            current.append(extractNumberedMemoryText(line) ?? line)
        } else if isRecordStart(line, expected: memories.count + 2, requireUUID: requireUUID) {
            // Defensive: a record start one ahead of expectation (never seen in
            // the harness layouts); close the current record and continue.
            memories.append(trimTrailingBlank(current).joined(separator: "\n")); current = [extractNumberedMemoryText(line) ?? line]
        } else {
            current.append(line)
        }
        i += 1
    }
    if !current.isEmpty { memories.append(trimTrailingBlank(current).joined(separator: "\n")) }
    guard !memories.isEmpty else { return nil }

    // Drop the blank separator lines that precede the footer marker.
    let header = lines[0..<first].joined(separator: "\n")
    let footer = lines[footerStart...].joined(separator: "\n")
    return ParsedReaderPrompt(header: header, memories: memories, footer: footer)
}

/// The integer at the start of a numbered line, or nil.
private func leadingNumber(_ line: String) -> Int? {
    let digits = line.prefix { $0.isNumber }
    return digits.isEmpty ? nil : Int(digits)
}

/// True when a record body opens with a drawer UUID (8-4-4-4-12 hex), the
/// harness's rendering of a retrieved memory's identity.
private func bodyOpensWithUUID(_ body: String) -> Bool {
    let scalars = Array(body.unicodeScalars.prefix(36))
    guard scalars.count == 36 else { return false }
    let hyphens: Set<Int> = [8, 13, 18, 23]
    for (i, c) in scalars.enumerated() {
        if hyphens.contains(i) { if c != "-" { return false } }
        else if !CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains(c) { return false }
    }
    return true
}

/// Removes trailing blank lines from a record block.
private func trimTrailingBlank(_ block: [String]) -> [String] {
    var b = block
    while let last = b.last, last.trimmingCharacters(in: .whitespaces).isEmpty { b.removeLast() }
    return b
}

/// Extracts the body of a "N. text" numbered memory line.
/// Returns nil when the line does not match the pattern.
/// Pattern: one-or-more digits, '. ' (dot space), then the memory body.
public func extractNumberedMemoryText(_ line: String) -> String? {
    var idx = line.startIndex
    // Require at least one digit.
    guard idx < line.endIndex, line[idx].isNumber else { return nil }
    while idx < line.endIndex, line[idx].isNumber {
        idx = line.index(after: idx)
    }
    // Require '. ' (dot then space).
    guard idx < line.endIndex, line[idx] == "." else { return nil }
    let afterDot = line.index(after: idx)
    guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
    let afterSpace = line.index(after: afterDot)
    // Memory body must be non-empty.
    guard afterSpace < line.endIndex else { return nil }
    return String(line[afterSpace...])
}

// MARK: - Chunk building

/// Groups `memories` into chunks such that `tokenCount(header + chunk + footer) ≤ roundBudget`.
///
/// Each memory is kept whole (never split mid-memory). When a single memory
/// exceeds the budget on its own it occupies its own chunk (best effort;
/// the engine will refuse only if the chunk is truly over its context limit,
/// which is a different, smaller budget than roundBudget).
///
/// Returns at least one chunk. If memories is empty the returned array holds
/// one empty chunk.
public func buildMemoryChunks(
    memories: [String],
    header: String,
    footer: String,
    roundBudget: Int
) -> [[String]] {
    guard !memories.isEmpty else { return [[]] }

    // Tokens consumed by the fixed parts of every round prompt (header + footer
    // + formatting overhead: a blank line between header and first memory, a
    // blank line after last memory before footer).
    let fixedTokens = appleAnswerEstimateTokens(header + "\n\n" + footer)
    // Budget available for the numbered memory lines in each chunk.
    let available = max(roundBudget - fixedTokens, 1)

    var chunks: [[String]] = []
    var current: [String] = []
    var currentTokens = 0

    for memory in memories {
        // Memory is formatted as "N. <body>" where N is 1-based index in chunk.
        let nextIndex = current.count + 1
        let formatted = "\(nextIndex). \(memory)"
        // +1 for the newline separator between entries.
        let lineTokens = appleAnswerEstimateTokens("\n" + formatted)

        if !current.isEmpty, currentTokens + lineTokens > available {
            // Flush and start a fresh chunk.
            chunks.append(current)
            current = [memory]
            currentTokens = appleAnswerEstimateTokens("1. \(memory)")
        } else {
            current.append(memory)
            currentTokens += lineTokens
        }
    }
    if !current.isEmpty { chunks.append(current) }
    return chunks
}

// MARK: - Prompt builders

/// Builds the per-chunk prompt for a map-reduce map round.
///
/// Instructs the model to note what the chunk says about the question,
/// copying numbers, dates, and names verbatim.
public func buildMapRoundPrompt(
    header: String,
    memories: [String],
    footer: String
) -> String {
    var parts: [String] = []
    if !header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        parts.append(header)
    }
    parts.append("") // blank line before memories
    for (i, mem) in memories.enumerated() {
        parts.append("\(i + 1). \(mem)")
    }
    parts.append(footer)
    // Map-round instruction appended after the question/answer footer so the
    // model produces a note rather than a final answer.
    parts.append(
        "\nFor this set of records only, state what is relevant to the question " +
        "above. Copy numbers, dates, and names verbatim. " +
        "Reply 'nothing relevant' if none of these records address it.")
    return parts.joined(separator: "\n")
}

/// Builds the final map-reduce prompt that combines collected notes into an answer.
public func buildMapReduceFinalPrompt(question: String, notes: [String]) -> String {
    var parts: [String] = [
        "You are answering a question based on notes collected from batches of memory records.",
        "Each note summarises what a batch said about the question.",
        "Give a direct, concise answer. Say \"I don't know.\" if no note is useful.",
        "",
        "Notes:",
    ]
    for (i, note) in notes.enumerated() {
        parts.append("\(i + 1). \(note)")
    }
    parts.append("")
    parts.append("Question: \(question)")
    parts.append("")
    parts.append("Answer:")
    return parts.joined(separator: "\n")
}

/// Builds the round-1 refine prompt (first chunk, no prior draft).
/// Reuses the original prompt layout so the model answers as normal.
public func buildRefineRound1Prompt(
    header: String,
    memories: [String],
    footer: String
) -> String {
    var parts: [String] = []
    if !header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        parts.append(header)
    }
    parts.append("")
    for (i, mem) in memories.enumerated() {
        parts.append("\(i + 1). \(mem)")
    }
    parts.append(footer)
    return parts.joined(separator: "\n")
}

/// Builds a refine continuation prompt (subsequent chunks, with a prior draft).
public func buildRefineContinuationPrompt(
    question: String,
    draft: String,
    memories: [String]
) -> String {
    var parts: [String] = [
        "You are refining an answer to a question as more memory records become available.",
        "Update the current draft if the new records add relevant detail; otherwise return the draft unchanged.",
        "",
        "Additional memory records:",
    ]
    for (i, mem) in memories.enumerated() {
        parts.append("\(i + 1). \(mem)")
    }
    parts.append("")
    parts.append("Current draft: \(draft)")
    parts.append("")
    parts.append("Question: \(question)")
    parts.append("")
    parts.append("Revised answer:")
    return parts.joined(separator: "\n")
}

/// Extracts the question text from the reader-prompt footer.
/// Looks for the first line starting with "Question: ".
public func extractQuestion(fromFooter footer: String) -> String {
    for line in footer.components(separatedBy: "\n") {
        if line.hasPrefix("Question: ") {
            return String(line.dropFirst("Question: ".count))
        }
    }
    return footer  // fallback: use entire footer as question
}

// MARK: - stderr summary

/// Returns the one-line stderr summary string for an apple-answer run.
///
/// Format: `apple-answer: mode=<m> rounds=<n> chunks=<c> max_round_tokens=<t>`
///
/// - Parameters:
///   - mode:           The reader mode name (e.g. "map-reduce").
///   - rounds:         Total number of model calls made.
///   - chunks:         Number of memory chunks the prompt was split into.
///   - maxRoundTokens: Largest estimated token count seen across all rounds.
public func appleAnswerStderrLine(
    mode: String,
    rounds: Int,
    chunks: Int,
    maxRoundTokens: Int
) -> String {
    "apple-answer: mode=\(mode) rounds=\(rounds) chunks=\(chunks) max_round_tokens=\(maxRoundTokens)"
}

// MARK: - Guided generation payload types (model-free, always testable)

/// Answer payload for guided generation.
///
/// The public Codable form is used by callers and tests without requiring
/// FoundationModels.  The private `@Generable` counterpart (`_GuidedAnswer`)
/// lives in AppleAnswerCLI.swift inside the FoundationModels conditional block
/// and drives the actual `session.respond(to:generating:)` call.
public struct GuidedAnswer: Codable, Sendable, Equatable {
    /// The answer text, or "I don't know." when abstaining.
    public var answer: String
    /// UUIDs of the memory records the answer draws on.
    public var evidence_ids: [String]
    /// True when the records do not contain the answer.
    public var abstain: Bool

    public init(answer: String, evidence_ids: [String], abstain: Bool) {
        self.answer = answer
        self.evidence_ids = evidence_ids
        self.abstain = abstain
    }
}

/// Pick list returned by the guided round-1 picker.
///
/// `picks` holds 1-based indices into the candidate list supplied to the model.
/// The @Generable counterpart (`_PickResult`) is in AppleAnswerCLI.swift.
public struct PickResult: Codable, Sendable, Equatable {
    /// 1-based indices of the selected candidate records, best first.
    public var picks: [Int]

    public init(picks: [Int]) { self.picks = picks }
}

// MARK: - Pick mode — candidate line builders and budget helpers

/// Parses a memory text into its header line and body.
///
/// Memory text format:
/// ```
/// <UUID> · <subject> · <bestSpan> · <sscFacts> · <event_time>
/// <body text …>
/// ```
///
/// Returns the first line as `headerLine` and everything after the first line
/// as `body`.
public func parsePickMemory(_ text: String) -> (headerLine: String, body: String) {
    let lines = text.components(separatedBy: "\n")
    let headerLine = lines.first ?? ""
    guard lines.count > 1 else { return (headerLine, "") }
    let bodyLines = Array(lines.dropFirst())
    return (headerLine, bodyLines.joined(separator: "\n"))
}

/// Builds one candidate line for the round-1 picker prompt.
///
/// Format: `<index>. <header line>`
///
/// The header line is the first line of `memoryText` (the UUID · subject · …
/// dense row).
public func buildPickCandidateLine(index: Int, memoryText: String) -> String {
    let (headerLine, _) = parsePickMemory(memoryText)
    return "\(index). \(headerLine)"
}

/// Builds the round-1 prompt for the picker.
///
/// Instructs the model to return at most `pickK` 1-based indices from the
/// candidate list, best first, without summarising or answering the question.
public func buildPickRound1Prompt(question: String, candidateLines: [String], pickK: Int) -> String {
    var parts: [String] = [
        "You are selecting the most relevant memory records to answer a question.",
        "Return at most \(pickK) indices from the list below, best first.",
        "Only return indices; do not summarise or answer the question.",
        "",
        "Candidates:",
        "",
    ]
    parts += candidateLines
    parts += ["", "Question: \(question)"]
    return parts.joined(separator: "\n")
}

/// Builds the round-2 prompt for the pick mode answer step.
///
/// Uses the standard reader format so the answer round is compatible with
/// `--guided` and with the plain `generateAppleAnswer` path.
public func buildPickRound2Prompt(question: String, pickedMemories: [String]) -> String {
    var parts: [String] = [
        "You are answering a question based on retrieved memory records.",
        "Read all records carefully and give a direct, concise answer.",
        "If the records do not contain the answer, say \"I don't know.\"",
        "",
        "Retrieved memory records:",
        "",
    ]
    for (i, mem) in pickedMemories.enumerated() {
        parts.append("\(i + 1). \(mem)")
    }
    parts += ["", "Question: \(question)", "", "Answer:"]
    return parts.joined(separator: "\n")
}

/// Clamps and deduplicates a raw picks list from the model.
///
/// - Discards indices outside `1…totalCount`.
/// - Deduplicates while preserving order.
/// - Truncates to at most `pickK` entries.
public func clampAndDedupPicks(picks: [Int], pickK: Int, totalCount: Int) -> [Int] {
    var seen = Set<Int>()
    var result: [Int] = []
    for p in picks {
        guard p >= 1, p <= totalCount, !seen.contains(p) else { continue }
        seen.insert(p)
        result.append(p)
        if result.count >= pickK { break }
    }
    return result
}

/// Counts how many picks must be dropped from the end so that the round-2
/// prompt fits within `roundBudget` tokens.
///
/// - Parameter pickedBodyTexts: Distilled bodies (header + body) for the
///   picks, in pick order.  At least one pick is always kept.
/// - Returns: The number of picks dropped from the tail.
public func dropPicksForRoundBudget(
    pickedBodyTexts: [String],
    question: String,
    roundBudget: Int
) -> Int {
    var count = pickedBodyTexts.count
    // Keep dropping from the end until the prompt fits or only one pick remains.
    while count > 1 {
        let bodies = Array(pickedBodyTexts.prefix(count))
        let prompt = buildPickRound2Prompt(question: question, pickedMemories: bodies)
        if appleAnswerEstimateTokens(prompt) <= roundBudget { break }
        count -= 1
    }
    return pickedBodyTexts.count - count
}

/// Accepts raw picks returned by the model for a single chunk and retains
/// only those that are valid global 1-based record indices.
///
/// Because candidate lines already carry globally-numbered labels (e.g.
/// "4. <header>"), the model returns the same global numbers it sees —
/// no offset translation is needed.  This function is platform-neutral and
/// intentionally free of FoundationModels so it is testable everywhere.
///
/// - SAFETY: only indices in `1...totalCount` survive; all others are dropped.
///
/// - Parameters:
///   - rawPicks: The raw integer list produced by the model for one chunk.
///   - totalCount: The total number of candidate records across all chunks.
/// - Returns: The indices from `rawPicks` that lie within `1…totalCount`.
public func resolveChunkedPickIndices(rawPicks: [Int], totalCount: Int) -> [Int] {
    // SAFETY: Guard enforces the full original-record range, not a per-chunk
    // range, because the model sees globally-numbered labels and returns
    // global indices.  No offset arithmetic — the labels are already correct.
    rawPicks.filter { $0 >= 1 && $0 <= totalCount }
}

/// Groups candidate lines into chunks so that each round-1 prompt fits within
/// `roundBudget`.
///
/// Returns the chunks as arrays of candidate lines (each chunk contains the
/// lines for that round-1 call).  Each candidate line retains its global
/// 1-based label (e.g. "4. <header>" for the 4th record) — the model returns
/// those global indices directly; no per-chunk offset translation is required.
public func buildPickCandidateChunks(
    candidateLines: [String],
    question: String,
    pickK: Int,
    roundBudget: Int
) -> [[String]] {
    // Tokens used by the round-1 prompt frame (preamble + question, no candidates).
    let baseTokens = appleAnswerEstimateTokens(
        buildPickRound1Prompt(question: question, candidateLines: [], pickK: pickK))
    let available = max(roundBudget - baseTokens, 1)

    var chunks: [[String]] = []
    var current: [String] = []
    var currentTokens = 0

    for line in candidateLines {
        // +1 accounts for the newline between candidate lines.
        let lineTokens = appleAnswerEstimateTokens("\n" + line)
        if !current.isEmpty, currentTokens + lineTokens > available {
            chunks.append(current)
            current = [line]
            currentTokens = lineTokens
        } else {
            current.append(line)
            currentTokens += lineTokens
        }
    }
    if !current.isEmpty { chunks.append(current) }
    return chunks.isEmpty ? [[]] : chunks
}

/// Returns the one-line stderr summary string for a pick-mode run.
///
/// Format: `apple-answer: mode=pick picks=<comma-list> rounds=<n> max_round_tokens=<t>`
///
/// - Parameter picks: 1-based original record indices in the order chosen.
public func appleAnswerPickStderrLine(picks: [Int], rounds: Int, maxRoundTokens: Int) -> String {
    let pickStr = picks.map(String.init).joined(separator: ",")
    return "apple-answer: mode=pick picks=\(pickStr) rounds=\(rounds) max_round_tokens=\(maxRoundTokens)"
}
