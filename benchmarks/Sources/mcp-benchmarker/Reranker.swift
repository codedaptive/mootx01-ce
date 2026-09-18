// Reranker.swift — post-retrieval reranking via an external command.
//
// `applyRerank(cmd:question:ids:previews:)` takes the current ranked hit list,
// builds a numbered candidate prompt, pipes it to the command, and returns the
// reranked list. The interface mirrors `--judge-cmd` (LongMemEvalJudge.swift):
// the command reads stdin and writes its reply to stdout with exit 0.
//
// SECRECY RULE: the command string carries API keys in typical usage. The report
// records PRESENCE ONLY (`rerank_cmd_set: Bool`). Never log, hash, or otherwise
// derive a value from the command text.
//
// Failure contract: subprocess errors and completely unparseable replies are
// non-fatal. The function returns the ORIGINAL ranked list and sets `failed =
// true` so the caller can increment its run-level `rerank_failures` counter.

import Foundation

// MARK: - Constants

/// Maximum number of candidates handed to the rerank command. Candidates beyond
/// this window keep their original relative positions after the reranked head.
let rerankWindowSize = 10

/// Maximum preview characters shown per candidate in the rerank prompt.
/// Keeps prompts token-lean while giving the model enough signal for ordering.
let rerankPreviewLength = 120

// MARK: - Public interface

/// Applies an external rerank command to a ranked hit list.
///
/// Builds a numbered prompt of the top `rerankWindowSize` candidates and pipes
/// it to `cmd` via `/bin/sh -c`. The reply is parsed for integers in
/// `[1, window]`. Named candidates move to the front in reply order; unnamed
/// candidates follow in their original relative order. Candidates beyond the
/// window are appended unchanged.
///
/// The command contract mirrors `--judge-cmd` (see `lmeRunJudge(cmd:prompt:)` in
/// LongMemEvalJudge.swift): stdin = UTF-8 prompt text, stdout = reply, exit 0.
///
/// - Parameters:
///   - cmd:      Shell command passed to `/bin/sh -c`. May carry API keys —
///               never logged, hashed, or recorded beyond a presence boolean.
///   - question: The benchmark question this recall result is answering.
///   - ids:      Current ranked hit IDs (ids[0] = rank 1). May be empty.
///   - previews: Per-ID text previews, parallel to `ids`. Shorter arrays and
///               missing entries are handled gracefully — missing previews use
///               an empty string.
/// - Returns:    The (possibly unchanged) ranked ID list and a failure flag.
///               `failed` is true when the subprocess returned a non-zero exit,
///               produced an un-parseable reply (no valid integers found), or
///               threw a launch error. Any of these conditions leaves `ids`
///               unchanged and increments the caller's `rerank_failures` counter.
func applyRerank(
    cmd: String,
    question: String,
    ids: [String],
    previews: [String]
) -> (rerankedIDs: [String], failed: Bool) {
    let window = min(rerankWindowSize, ids.count)
    guard window > 0 else {
        // Nothing to rerank — treat as success, empty failure.
        return (ids, false)
    }

    let prompt = buildRerankPrompt(question: question, ids: ids, previews: previews, window: window)

    guard let reply = runRerankSubprocess(cmd: cmd, prompt: prompt) else {
        // Subprocess failure (launch error or non-zero exit).
        return (ids, true)
    }

    let namedPositions = parseRerankReply(reply, windowSize: window)
    guard !namedPositions.isEmpty else {
        // Completely unparseable reply (no valid integers found).
        return (ids, true)
    }

    let reranked = applyPermutation(ids: ids, named: namedPositions, window: window)
    return (reranked, false)
}

// MARK: - Prompt construction

/// Builds the rerank prompt from the question and the top-`window` candidates.
///
/// Format:
/// ```
/// Rerank the following memory candidates for the question below.
/// Reply with candidate numbers, best first, space- or comma-separated.
/// Omitted candidates remain in their original relative order after the ones you list.
///
/// Question: <question>
///
/// Candidates:
/// 1. <id>: <preview (up to 120 chars)>
/// 2. <id>: <preview>
/// ...
/// ```
func buildRerankPrompt(question: String, ids: [String], previews: [String], window: Int) -> String {
    var lines: [String] = [
        "Rerank the following memory candidates for the question below.",
        "Reply with candidate numbers, best first, space- or comma-separated.",
        "Omitted candidates remain in their original relative order after the ones you list.",
        "",
        "Question: \(question)",
        "",
        "Candidates:",
    ]
    for i in 0..<window {
        let id = ids[i]
        let rawPreview = i < previews.count ? previews[i] : ""
        // Truncate preview to keep prompt size predictable.
        let preview = rawPreview.count > rerankPreviewLength
            ? String(rawPreview.prefix(rerankPreviewLength))
            : rawPreview
        lines.append("\(i + 1). \(id): \(preview)")
    }
    return lines.joined(separator: "\n")
}

// MARK: - Subprocess invocation

/// Runs the rerank command as a subprocess. Returns the stdout string on exit 0,
/// nil on launch error, non-zero exit, or timeout.
///
/// Delegates to `runBoundedCmdSubprocess` — the one subprocess seam shared
/// with the judge runner — so every stage of the child's lifecycle (exit
/// wait, TERM→KILL escalation, post-exit pipe drains) is bounded. Any bound
/// firing reads as a rerank failure (nil): `applyRerank` increments
/// rerank_failures and leaves the ranking unchanged.
func runRerankSubprocess(cmd: String, prompt: String) -> String? {
    guard let result = try? runBoundedCmdSubprocess(cmd: cmd, prompt: prompt) else {
        // Launch failure or timeout — both read as rerank failure.
        return nil
    }
    guard result.terminationStatus == 0 else { return nil }
    return String(data: result.stdout, encoding: .utf8)
}

// MARK: - Reply parsing

/// Parses a rerank reply for integers in `[1, windowSize]`, deduplicating in
/// first-seen order. Treats commas and all whitespace characters as delimiters.
///
/// Returns the ordered list of valid, unique candidate numbers found in the
/// reply. Returns an empty array when none are found (counts as failure in
/// `applyRerank`).
func parseRerankReply(_ reply: String, windowSize: Int) -> [Int] {
    // Split on whitespace and commas.
    let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))
    let tokens = reply.components(separatedBy: separators)
    var result: [Int] = []
    var seen = Set<Int>()
    for token in tokens {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let n = Int(trimmed),
              n >= 1, n <= windowSize,
              seen.insert(n).inserted
        else { continue }
        result.append(n)
    }
    return result
}

// MARK: - Permutation application

/// Applies a partial permutation to the ranked ID list.
///
/// `named` is an ordered list of 1-based candidate positions from the reply.
/// Named candidates are placed first in reply order. Unnamed candidates within
/// the window follow in their original relative order. Candidates beyond
/// `window` are appended unchanged.
///
/// - Parameters:
///   - ids:    Full ranked ID list.
///   - named:  1-based positions from the reply (deduplicated, ordered).
///   - window: Number of candidates that were presented to the reranker.
func applyPermutation(ids: [String], named: [Int], window: Int) -> [String] {
    var result: [String] = []
    result.reserveCapacity(ids.count)

    let namedSet = Set(named)

    // Named candidates in reply order (convert 1-based to 0-based).
    for n in named {
        result.append(ids[n - 1])
    }
    // Unnamed candidates within the window in original relative order.
    for i in 0..<window {
        if !namedSet.contains(i + 1) {
            result.append(ids[i])
        }
    }
    // Candidates beyond the window keep their positions.
    result.append(contentsOf: ids[window...])

    return result
}
