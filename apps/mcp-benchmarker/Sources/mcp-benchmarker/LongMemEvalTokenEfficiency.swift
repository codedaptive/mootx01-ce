import Foundation

// LongMemEvalTokenEfficiency.swift — Token estimator and evidence-density scorer.
//
// Two pure functions that are the core of the LME-03 token-efficiency benchmark:
//
//   lmeEstimateTokens(_:)      — deterministic token count approximation
//   lmeEvidenceHit(evidenceText:payloadText:) — normalized-overlap evidence match
//
// Both are conformance-vectored: conformance/token_efficiency_vectors.json drives
// BOTH the Swift leg (this file) and the Rust twin, ensuring cross-language
// numeric agreement on every input.
//
// Design constraints:
//   - Zero external dependencies: no tiktoken, no ML inference.
//   - Deterministic on all inputs (no randomness, no system locale).
//   - Consistent across Swift and Rust (same algorithm, same edge-case handling).
//   - The metric compares arms AGAINST EACH OTHER, so consistency matters
//     more than tiktoken-level absolute fidelity.
//
// Token estimator algorithm:
//   UTF-8 byte count, ceiling-divided by 4.
//   Rationale: contemporary tokenizers average ~4 bytes/token on English prose.
//   Ceiling ensures 1 byte → 1 token (never zero for non-empty text).
//   Formula: (utf8ByteCount + 3) / 4   [integer ceiling division]
//
// Evidence hit algorithm:
//   Normalize both strings (lowercase, trim, collapse whitespace runs to one space),
//   then check if the normalized evidence is a substring of the normalized payload.
//   Returns false for empty evidence text (no evidence to match against = no hit).
//   Rationale: conservative and verifiable; a factoid survives the payload if its
//   key phrase appears verbatim (case-insensitively) somewhere in the returned text.

// MARK: - Token estimator

/// Estimates the token count of a string using the UTF-8 byte approximation.
///
/// Algorithm: `(utf8ByteCount + 3) / 4` (ceiling integer division).
/// - A 4-byte ASCII word counts as 1 token.
/// - A 1-byte string (single ASCII char) counts as 1 token (never 0).
/// - Multi-byte UTF-8 characters count proportionally more (a 2-byte character
///   contributes 0.5 tokens on average, matching the ~4 bytes/token heuristic).
///
/// This estimator is documented in the report so readers can reproduce it.
/// Both Swift and Rust produce identical results for the same input — verified
/// by conformance/token_efficiency_vectors.json.
///
/// - Parameter text: The string to estimate token count for.
/// - Returns: Estimated token count, ≥ 0 (0 only for empty string).
func lmeEstimateTokens(_ text: String) -> Int {
    let byteCount = text.utf8.count
    // Ceiling division: (n + d-1) / d with d=4.
    // For byteCount=0 this returns 0; for byteCount=1..4 returns 1; etc.
    return (byteCount + 3) / 4
}

// MARK: - Evidence normalization

/// Normalizes a string for evidence-hit comparison.
///
/// Normalization steps:
///   1. Lowercase.
///   2. Trim leading/trailing whitespace and newlines.
///   3. Collapse all internal runs of whitespace (including newlines) to a
///      single space.
///
/// This makes the comparison robust to minor formatting differences between
/// how the turn was stored (newline-separated) and how the payload reports it
/// (space-separated). Both the evidence text (from `has_answer` turns) and
/// the MCP payload text pass through the same normalizer before comparison.
func lmeNormalizeForEvidence(_ text: String) -> String {
    // Split on whitespace (including newlines), drop empties, rejoin with space.
    text.lowercased()
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

// MARK: - Evidence-density hit

/// Returns true when the evidence text appears (case-insensitively) in the payload.
///
/// Both arguments are normalized before comparison (see `lmeNormalizeForEvidence`).
/// The check is a substring match: the full normalized evidence phrase must appear
/// contiguously in the normalized payload.
///
/// - Parameters:
///   - evidenceText: The reference text to look for (from `has_answer` turns).
///   - payloadText: The MCP payload text to search within.
/// - Returns: true when normalized evidence is a substring of normalized payload;
///   false when evidence is empty or not found.
///
/// Empty `evidenceText` always returns false — there is nothing to confirm.
/// This is the correct behavior when the corpus omits `has_answer` annotations
/// (the real HuggingFace longmemeval corpus): absence of evidence text is not
/// evidence of a hit.
func lmeEvidenceHit(evidenceText: String, payloadText: String) -> Bool {
    let normalizedEvidence = lmeNormalizeForEvidence(evidenceText)
    guard !normalizedEvidence.isEmpty else { return false }
    let normalizedPayload = lmeNormalizeForEvidence(payloadText)
    return normalizedPayload.contains(normalizedEvidence)
}

// MARK: - Evidence text extraction

/// Extracts the evidence text for a question from its `has_answer` turns.
///
/// Walks the answer sessions in haystack order, finds all turns where
/// `LMETurn.hasAnswer == true`, and joins their content with a space separator.
///
/// Returns nil when no `has_answer` turns are present (the real HuggingFace
/// corpus does not include this field; only the hand-authored synthetic sample
/// does). A nil return means the evidence-hit score is unavailable for this
/// question — callers should treat it as an "unknown" result rather than a miss.
///
/// - Parameter question: The LMEQuestion to extract evidence text from.
/// - Returns: Joined has_answer turn content, or nil if no has_answer turns exist.
func lmeEvidenceTextForQuestion(_ question: LMEQuestion) -> String? {
    let answerSessionSet = Set(question.answerSessionIDs)
    var parts: [String] = []
    for (idx, sessionID) in question.haystackSessionIDs.enumerated() {
        guard answerSessionSet.contains(sessionID) else { continue }
        let session = question.haystackSessions[idx]
        for turn in session where turn.hasAnswer {
            parts.append(turn.content)
        }
    }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
}
