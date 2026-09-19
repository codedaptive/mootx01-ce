// SubjectGenerator.swift — deterministic AI-facing subject from record content.
//
// CANONICAL ALGORITHM. The Rust twin in subject_generator.rs must produce
// bit-identical output on the same inputs. Conformance is gated by
// conformance/subject_vectors.json which is driven by both legs.
//
// BACKGROUND. PR-02 added a required `subject` arg to moot_file_memory (≤120
// chars). Before PR-07, every ingest site in the harness passed
// `content.prefix(120)` — a raw truncation that cuts mid-sentence and yields
// low-signal subjects. The deterministic subject generator improves ingest
// fidelity by extracting a complete first sentence instead.
//
// ALGORITHM (in order of application):
//   1. Trim leading and trailing Unicode whitespace (including newlines) from
//      the content string.
//   2. Scan left-to-right for the first sentence boundary: a period ('.'),
//      question mark ('?'), or exclamation mark ('!') followed by an ASCII
//      whitespace character (space 0x20, newline 0x0A, carriage return 0x0D,
//      or tab 0x09) OR by end-of-string.
//   3. Decimal points are NOT boundaries: a period immediately followed by a
//      decimal digit (0-9) is a numeric literal component (e.g. "1.8 m/s")
//      and is skipped without triggering a boundary.
//   4. When a boundary is found, extract from the start of the trimmed string
//      through and including the punctuation character (exclusive of the
//      following whitespace), then trim the result.
//   5. When no boundary is found, use the entire trimmed string.
//   6. Cap the result at 120 Unicode extended grapheme clusters via
//      String.prefix(120). The Rust port uses chars().take(120) (Unicode
//      scalar values). For all ASCII corpus content these two measures agree.

import Foundation

/// Generates a deterministic AI-facing subject from record content.
///
/// Returns the first complete sentence of the trimmed content, capped at 120
/// characters. When no sentence boundary is found, returns the entire trimmed
/// content (or its first 120 chars). Empty or whitespace-only input returns
/// an empty string.
///
/// This function is pure: same input always produces the same output. It
/// contains no randomness, no clock reads, and no I/O. Suitable for use at
/// corpus-generation time where subject stability across runs is required.
public func deterministicSubject(_ content: String) -> String {
    let t = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return "" }

    // Scan character by character. Swift String.Index arithmetic is O(n) on
    // UTF-8 storage; iterating with a manual index avoids repeated re-scanning
    // from the start and keeps the scan a single linear pass.
    var cutIndex: String.Index? = nil
    var idx = t.startIndex
    while idx < t.endIndex {
        let c = t[idx]
        if c == "." || c == "?" || c == "!" {
            let next = t.index(after: idx)
            // A period followed by a decimal digit is a numeric literal
            // separator (e.g. "3.14"), not a sentence boundary. All other
            // punctuation-then-whitespace (or punctuation-then-end) patterns
            // trigger a boundary.
            if c == "." && next < t.endIndex && t[next].isNumber {
                // Decimal point — skip, not a boundary.
                idx = t.index(after: idx)
                continue
            }
            if next >= t.endIndex
                || t[next] == " " || t[next] == "\n"
                || t[next] == "\r" || t[next] == "\t" {
                // Cut position is the index immediately past the punctuation
                // char (exclusive upper bound for the sentence slice).
                cutIndex = next
                break
            }
        }
        idx = t.index(after: idx)
    }

    let sentence: String
    if let cut = cutIndex {
        // Slice from start up to (not including) the whitespace after the
        // punctuation, then strip any trailing whitespace the slice may have
        // acquired (handles punctuation-at-end-of-string where cut == endIndex).
        sentence = String(t[t.startIndex..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
        sentence = t
    }

    // Normalize embedded newlines to spaces BEFORE the length cap. A CRLF
    // pair is ONE grapheme cluster, so capping first let a later per-scalar
    // newline replacement (the seed writer's join) grow the subject past the
    // product's 120-char contract — measured live on LongMemEval-m question
    // 8b9d4367 (123 chars, import rejected). Per-scalar 1:1 replacement plus
    // trim is identical to the old order for every subject the old order
    // produced within contract; it differs only where the old output was
    // rejected. The single-line result also satisfies the product's
    // multiline and untrimmed subject rules at the live moot_file_memory
    // boundary, not just the seed path.
    let singleLine = sentence
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)

    // Cap at 120 extended grapheme clusters. For ASCII content this matches
    // the Rust port's chars().take(120) exactly. Trim again: the cap can
    // land immediately after a space, and the row renderer never trims.
    return String(singleLine.prefix(120))
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
