// ContextShape.swift
// Port of record_shape_classifier.py — classify_record and all helpers.
//
// Design rules (from the decision record):
//   - NO regex engine (no NSRegularExpression, no Swift Regex).
//     Each Python `re.compile` pattern is a hand-written Unicode-scalar scanner.
//   - Index unit: unicodeScalars (Python str uses code points, Swift unicodeScalars
//     is the same unit).  String.count (grapheme clusters) is NEVER used for length.
//   - Python integer semantics: all division uses Swift's `/` on Int, which is
//     truncating-toward-zero.  For non-negative operands this equals Python's `//`
//     (floor division).
//   - Stable sort: Python's sort is stable; Swift's `sorted` is also stable, so
//     tie-breaking by label name is automatic.
//   - No Date(), no randomness.  Pure functions.

import Foundation

// MARK: - KNOWN_SPEAKERS
// Mirrors: KNOWN_SPEAKERS in record_shape_classifier.py
private let knownSpeakers: Set<String> = [
    "user", "assistant", "human", "system", "customer", "agent",
    "interviewer", "interviewee", "speaker", "participant",
]

// MARK: - Scalar-level predicates

/// True for the six ASCII whitespace characters that Python's `\s` matches in
/// the ASCII range: space (0x20), tab (0x09), newline (0x0A), CR (0x0D),
/// form-feed (0x0C), vertical-tab (0x0B).
///
/// These are the only whitespace chars needed by TAG_LINE, DATE_LEAD, BULLET_LEAD,
/// HEADING_LEAD, and the pipe-split pattern.  Unicode-whitespace cases in Python's
/// `\s` do not appear in the oracle vector content.
@inline(__always)
private func isWS(_ s: Unicode.Scalar) -> Bool {
    let v = s.value
    return v == 0x20 || v == 0x09 || v == 0x0A || v == 0x0D || v == 0x0C || v == 0x0B
}

/// True for ASCII digits 0–9. Mirrors `\d` in the ASCII range.
@inline(__always)
private func isDigit(_ s: Unicode.Scalar) -> Bool {
    s.value >= 0x30 && s.value <= 0x39
}

/// True for ASCII letters A–Z or a–z.
@inline(__always)
private func isLetter(_ s: Unicode.Scalar) -> Bool {
    let v = s.value
    return (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
}

/// True for Python `\w` in the ASCII range: [A-Za-z0-9_].
/// Used for word-boundary `\b` checks in DATE_ANY, NUMBER_ANY, and EMAIL.
@inline(__always)
private func isWordChar(_ s: Unicode.Scalar) -> Bool {
    let v = s.value
    return (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) ||
           (v >= 0x30 && v <= 0x39) || v == 0x5F
}

/// True for [A-Za-z0-9_ -]: characters allowed inside TAG_LINE's captured group.
@inline(__always)
private func isTagBodyChar(_ s: Unicode.Scalar) -> Bool {
    let v = s.value
    return (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) ||
           (v >= 0x30 && v <= 0x39) || v == 0x5F || v == 0x20 || v == 0x2D
}

/// True when `i` is a word-boundary START: the position before `i` is non-word
/// (or `i` is the beginning of the view).
///
/// Mirrors Python `\b` at the leftmost boundary of a pattern match.
@inline(__always)
private func isWBStart(_ v: String.UnicodeScalarView, at i: String.UnicodeScalarView.Index) -> Bool {
    i == v.startIndex || !isWordChar(v[v.index(before: i)])
}

/// True when `i` is a word-boundary END: the scalar at `i` is non-word
/// (or `i` is past the end of the view).
///
/// Mirrors Python `\b` at the rightmost boundary of a pattern match.
@inline(__always)
private func isWBEnd(_ v: String.UnicodeScalarView, at i: String.UnicodeScalarView.Index) -> Bool {
    i >= v.endIndex || !isWordChar(v[i])
}

// MARK: - Fixed-count digit scanner

/// Advances from `i` by exactly `count` ASCII digit scalars.
/// Returns the index immediately after the last digit, or nil if
/// fewer than `count` consecutive digits are present.
private func tryDigits(
    _ v: String.UnicodeScalarView,
    from i: String.UnicodeScalarView.Index,
    count: Int
) -> String.UnicodeScalarView.Index? {
    var j = i
    for _ in 0..<count {
        guard j < v.endIndex && isDigit(v[j]) else { return nil }
        j = v.index(after: j)
    }
    return j
}

// MARK: - TAG_LINE scanner
// Python:  TAG_LINE = re.compile(r"^\s*([A-Za-z][A-Za-z0-9_ -]{0,23}):\s*(.*)$")
//
// group(1) captures [A-Za-z][A-Za-z0-9_ -]{0,23} then .strip().lower() is applied.
// group(2) captures everything after the optional whitespace following ':'.
//
// Python str.strip() removes leading and trailing Unicode whitespace.  In practice
// the captured group can have trailing spaces (e.g. "Section A " before the ':')
// which strip() removes.  Swift replicates this with trimmingCharacters.

/// Returns `(tag, body)` when `line` matches TAG_LINE, where
/// `tag = group(1).strip().lower()` and `body = group(2)`.
/// Returns nil when the pattern does not match.
///
/// Mirrors TAG_LINE.match(line) in record_shape_classifier.py.
private func matchTagLine(_ line: String) -> (tag: String, body: String)? {
    let v = line.unicodeScalars
    var i = v.startIndex

    // Skip leading \s*
    while i < v.endIndex && isWS(v[i]) { i = v.index(after: i) }

    // First character must be [A-Za-z]
    guard i < v.endIndex && isLetter(v[i]) else { return nil }

    let tagStart = i
    i = v.index(after: i)  // consume the first letter

    // [A-Za-z0-9_ -]{0,23}: up to 23 additional tag-body characters
    var extra = 0
    while i < v.endIndex && extra < 23 && isTagBodyChar(v[i]) {
        i = v.index(after: i)
        extra += 1
    }
    let tagEnd = i  // end of group(1) raw text

    // Must find ':'
    guard i < v.endIndex && v[i].value == 0x3A /* : */ else { return nil }
    i = v.index(after: i)  // consume ':'

    // Skip optional \s* after ':'
    while i < v.endIndex && isWS(v[i]) { i = v.index(after: i) }

    // group(1).strip().lower() — strip() removes surrounding whitespace from the
    // raw match; lower() normalises to lower-case for speaker lookup.
    // Python str.strip() removes leading and trailing whitespace; the leading part
    // was already consumed (we started after the required [A-Za-z]), so only trailing
    // spaces in the matched region need removal.
    let rawTag = String(v[tagStart..<tagEnd])
    let tag = rawTag.trimmingCharacters(in: .whitespaces).lowercased()

    // group(2) = rest of line after the optional whitespace
    let body = String(v[i...])

    return (tag: tag, body: body)
}

// MARK: - DATE_LEAD scanner
// Python:
//   DATE_LEAD = re.compile(
//       r"^\s*(?:\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2})?)?"
//       r"|\d{1,2}[/-]\d{1,2}[/-]\d{2,4})\b"
//   )
//
// The optional T-time suffix `(?:T\d{2}:\d{2}(?::\d{2})?)?` is tried greedily.
// Python's backtracking engine rolls back the optional parts when the trailing \b
// would otherwise fail.  The scanner replicates this by trying from longest
// (date+Thh:mm:ss) to shortest (date-only) and accepting the first form that
// satisfies the boundary.

/// Returns true when `line` starts with optional whitespace followed by a date
/// in ISO (YYYY-MM-DD[Thh:mm[:ss]]) or short (M-D-YY etc.) form at a word boundary.
///
/// Mirrors `bool(DATE_LEAD.match(line))` in record_shape_classifier.py.
private func matchDateLead(_ line: String) -> Bool {
    let v = line.unicodeScalars
    var i = v.startIndex
    while i < v.endIndex && isWS(v[i]) { i = v.index(after: i) }
    guard i < v.endIndex && isDigit(v[i]) else { return false }

    // Try ISO date first (with backtracking over time suffix)
    if let end = tryISODateBacktrack(v, from: i), isWBEnd(v, at: end) { return true }

    // Try short date
    if let end = tryShortDate(v, from: i), isWBEnd(v, at: end) { return true }

    return false
}

// MARK: - DATE_ANY scanner (for countDateAny)
// Python:
//   DATE_ANY = re.compile(
//       r"\b(?:\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2})?)?"
//       r"|\d{1,2}[/-]\d{1,2}[/-]\d{2,4}|\d{4})\b"
//   )
//
// Three alternatives in order: ISO date, short date, 4-digit year.
// Python alternation: the first alternative that succeeds (including after
// backtracking within it) is used.  This scanner follows the same order.

/// Attempts ISO date pattern \d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2})?)?
/// with backtracking: tries longest match first (date+T+hh:mm:ss), then shorter
/// forms, returning the first end index that satisfies the trailing \b.
/// Returns nil when no version satisfies the boundary.
///
/// Used by both `matchDateLead` and `countDateAny`.
private func tryISODateBacktrack(
    _ v: String.UnicodeScalarView,
    from i: String.UnicodeScalarView.Index
) -> String.UnicodeScalarView.Index? {
    // \d{4}
    guard let y4 = tryDigits(v, from: i, count: 4) else { return nil }
    // '-'
    guard y4 < v.endIndex && v[y4].value == 0x2D else { return nil }
    let a1 = v.index(after: y4)
    // \d{2}
    guard let m2 = tryDigits(v, from: a1, count: 2) else { return nil }
    // '-'
    guard m2 < v.endIndex && v[m2].value == 0x2D else { return nil }
    let a2 = v.index(after: m2)
    // \d{2}
    guard let d2 = tryDigits(v, from: a2, count: 2) else { return nil }

    // Collect candidate end positions from longest to shortest
    var candidates: [String.UnicodeScalarView.Index] = []

    // Optional T time: T\d{2}:\d{2}(?::\d{2})?
    if d2 < v.endIndex && v[d2].value == 0x54 /* T */ {
        let aT = v.index(after: d2)
        if let h2 = tryDigits(v, from: aT, count: 2),
           h2 < v.endIndex && v[h2].value == 0x3A /* : */,
           let mn2 = tryDigits(v, from: v.index(after: h2), count: 2) {
            // Optional :ss
            if mn2 < v.endIndex && v[mn2].value == 0x3A,
               let sc2 = tryDigits(v, from: v.index(after: mn2), count: 2) {
                candidates.append(sc2)  // date+Thh:mm:ss
            }
            candidates.append(mn2)  // date+Thh:mm
        }
        // If T-parsing fails, fall through to date-only below
    }
    candidates.append(d2)  // date-only

    // Return the first candidate that satisfies the trailing \b
    for end in candidates where isWBEnd(v, at: end) {
        return end
    }
    return nil
}

/// Attempts short-date pattern \d{1,2}[/-]\d{1,2}[/-]\d{2,4}.
/// Returns the end index, or nil when the pattern does not match.
private func tryShortDate(
    _ v: String.UnicodeScalarView,
    from i: String.UnicodeScalarView.Index
) -> String.UnicodeScalarView.Index? {
    var j = i
    // \d{1,2}
    guard j < v.endIndex && isDigit(v[j]) else { return nil }
    j = v.index(after: j)
    if j < v.endIndex && isDigit(v[j]) { j = v.index(after: j) }
    // [/-]
    guard j < v.endIndex && (v[j].value == 0x2F || v[j].value == 0x2D) else { return nil }
    j = v.index(after: j)
    // \d{1,2}
    guard j < v.endIndex && isDigit(v[j]) else { return nil }
    j = v.index(after: j)
    if j < v.endIndex && isDigit(v[j]) { j = v.index(after: j) }
    // [/-]
    guard j < v.endIndex && (v[j].value == 0x2F || v[j].value == 0x2D) else { return nil }
    j = v.index(after: j)
    // \d{2,4}
    var digitCount = 0
    while j < v.endIndex && isDigit(v[j]) && digitCount < 4 {
        j = v.index(after: j)
        digitCount += 1
    }
    guard digitCount >= 2 else { return nil }
    return j
}

// MARK: - BULLET_LEAD scanner
// Python: BULLET_LEAD = re.compile(r"^\s*(?:[-*+]\s+|\d+[.)]\s+)")
//
// Matches: optional whitespace, then either a dash/asterisk/plus followed by
// at least one whitespace, or one-or-more digits then period-or-paren then
// at least one whitespace.

/// Returns true when `line` starts with optional whitespace followed by a
/// list-item bullet marker ([-*+] or numbered) and at least one space.
///
/// Mirrors `bool(BULLET_LEAD.match(line))` in record_shape_classifier.py.
private func matchBulletLead(_ line: String) -> Bool {
    let v = line.unicodeScalars
    var i = v.startIndex
    while i < v.endIndex && isWS(v[i]) { i = v.index(after: i) }
    guard i < v.endIndex else { return false }

    let ch = v[i].value

    // [-*+]\s+
    if ch == 0x2D || ch == 0x2A || ch == 0x2B {
        let next = v.index(after: i)
        return next < v.endIndex && isWS(v[next])
    }

    // \d+[.)]\s+
    if isDigit(v[i]) {
        var j = i
        while j < v.endIndex && isDigit(v[j]) { j = v.index(after: j) }
        guard j < v.endIndex && (v[j].value == 0x2E || v[j].value == 0x29) else { return false }
        let afterMark = v.index(after: j)
        return afterMark < v.endIndex && isWS(v[afterMark])
    }

    return false
}

// MARK: - HEADING_LEAD scanner
// Python:
//   HEADING_LEAD = re.compile(
//       r"^\s*(?:chapter|section|part|act|scene|title|book summary)\b",
//       re.IGNORECASE,
//   )
//
// The two-word keyword "book summary" requires matching two tokens.
// Case-insensitive matching is done by lowercasing the remaining line.
// \b after the keyword means the next character is not [A-Za-z0-9_].

/// The seven heading keywords, in longest-first order.
/// "book summary" is two words and must be checked before single-word keywords
/// that share a prefix.
private let headingKeywords: [String] = [
    "book summary", "chapter", "section", "part", "act", "scene", "title",
]

/// Returns true when `line` starts with optional whitespace followed by a heading
/// keyword (case-insensitive) at a word boundary.
///
/// Mirrors `bool(HEADING_LEAD.match(line))` in record_shape_classifier.py.
/// Python re.IGNORECASE is implemented by lowercasing the remaining suffix.
/// Divergence from Python: Python lowercases via Unicode full-case folding;
/// this scanner uses Swift's `lowercased()` which also uses Unicode full-case
/// folding.  For the pure-ASCII keywords and ASCII source content in the oracle
/// vectors, the results are identical.
private func matchHeadingLead(_ line: String) -> Bool {
    let v = line.unicodeScalars
    var i = v.startIndex
    while i < v.endIndex && isWS(v[i]) { i = v.index(after: i) }
    guard i < v.endIndex else { return false }

    // Lower-case the remaining suffix for case-insensitive comparison.
    // All keywords are ASCII so lowercased() is a simple XOR-0x20 on letters.
    let remaining = String(v[i...]).lowercased()
    let remV = remaining.unicodeScalars

    for kw in headingKeywords {
        guard remaining.hasPrefix(kw) else { continue }
        let kwLen = kw.unicodeScalars.count
        if kwLen >= remV.count {
            return true  // keyword fills the remaining string; \b at EOI ✓
        }
        let afterKw = remV.index(remV.startIndex, offsetBy: kwLen)
        if !isWordChar(remV[afterKw]) {
            return true  // next char is non-word → \b ✓
        }
    }
    return false
}

// MARK: - Pipe split
// Python: re.split(r"\s+\|\s+", content)
//
// Splits on one-or-more whitespace, pipe character '|', one-or-more whitespace.
// A bare '|' without surrounding whitespace is NOT a separator.
// The split returns all segments including the leading and trailing portions.

/// Splits `content` at every occurrence of `\s+\|\s+`.
///
/// Mirrors `re.split(r"\s+\|\s+", content)` in record_shape_classifier.py.
private func splitByPipe(_ content: String) -> [String] {
    let v = content.unicodeScalars
    var parts: [String] = []
    var partStart = v.startIndex
    var i = v.startIndex

    while i < v.endIndex {
        guard v[i].value == 0x7C /* | */ else { i = v.index(after: i); continue }

        // Need at least one \s immediately before '|' (within the current part)
        guard i > partStart else { i = v.index(after: i); continue }
        let prevIdx = v.index(before: i)
        guard isWS(v[prevIdx]) else { i = v.index(after: i); continue }

        // Need at least one \s immediately after '|'
        let nextIdx = v.index(after: i)
        guard nextIdx < v.endIndex && isWS(v[nextIdx]) else { i = v.index(after: i); continue }

        // Found a valid separator.  Scan back to the start of the leading \s+.
        var sepStart = i
        while sepStart > partStart {
            let prev = v.index(before: sepStart)
            if isWS(v[prev]) { sepStart = prev } else { break }
        }

        // Scan forward past the trailing \s+ to find the start of the next part.
        var sepEnd = nextIdx
        while sepEnd < v.endIndex && isWS(v[sepEnd]) { sepEnd = v.index(after: sepEnd) }

        parts.append(String(v[partStart..<sepStart]))
        partStart = sepEnd
        i = sepEnd
    }

    parts.append(String(v[partStart...]))
    return parts
}

// MARK: - countDateAny
// Python:
//   DATE_ANY = re.compile(
//       r"\b(?:\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2})?)?"
//       r"|\d{1,2}[/-]\d{1,2}[/-]\d{2,4}|\d{4})\b"
//   )
//   date_mentions = len(DATE_ANY.findall(content))
//
// Alternation order: ISO date (longest) → short date → 4-digit year (shortest).
// Python's regex engine uses the first alternative that succeeds (with backtracking
// within each alternative).  This scanner follows the same order.

/// Counts all non-overlapping DATE_ANY matches in `content`.
///
/// Mirrors `len(DATE_ANY.findall(content))` in record_shape_classifier.py.
private func countDateAny(_ content: String) -> Int {
    let v = content.unicodeScalars
    var count = 0
    var i = v.startIndex

    while i < v.endIndex {
        // \b requires the position to be a word-boundary start and the current
        // char to be a digit (all three date alternatives start with \d).
        guard isDigit(v[i]) && isWBStart(v, at: i) else {
            i = v.index(after: i)
            continue
        }

        // Alternative 1: ISO date \d{4}-\d{2}-\d{2}(?:T...)?
        if let end = tryISODateBacktrack(v, from: i) {
            count += 1
            i = end
            continue
        }

        // Alternative 2: short date \d{1,2}[/-]\d{1,2}[/-]\d{2,4}
        if let end = tryShortDate(v, from: i), isWBEnd(v, at: end) {
            count += 1
            i = end
            continue
        }

        // Alternative 3: 4-digit year \d{4}
        if let end = tryDigits(v, from: i, count: 4), isWBEnd(v, at: end) {
            count += 1
            i = end
            continue
        }

        // No alternative matched at this position; advance one scalar.
        i = v.index(after: i)
    }
    return count
}

// MARK: - countNumberAny
// Python:
//   NUMBER_ANY = re.compile(r"\b\d+(?:[.,]\d+)?\b")
//   number_mentions = len(NUMBER_ANY.findall(content))
//
// Matches: word boundary, one or more digits, optionally a decimal separator
// (period or comma) followed by more digits, word boundary.

/// Counts all non-overlapping NUMBER_ANY matches in `content`.
///
/// Mirrors `len(NUMBER_ANY.findall(content))` in record_shape_classifier.py.
///
/// Python's regex engine backtracks over the optional `(?:[.,]\d+)?` group when the
/// trailing `\b` would otherwise fail.  For example, "1,234a" matches "1" (not
/// "1,234") because consuming the optional group leaves "4a" with no word boundary,
/// but the mandatory-only match "1" has a boundary before ",".  This function
/// replicates that backtracking by checking `isWBEnd` at the mandatory-only position
/// whenever the extended (with optional) position fails.
private func countNumberAny(_ content: String) -> Int {
    let v = content.unicodeScalars
    var count = 0
    var i = v.startIndex

    while i < v.endIndex {
        guard isDigit(v[i]) && isWBStart(v, at: i) else {
            i = v.index(after: i)
            continue
        }

        // \d+: consume one or more digits — record end of mandatory portion.
        var afterMandatory = i
        while afterMandatory < v.endIndex && isDigit(v[afterMandatory]) {
            afterMandatory = v.index(after: afterMandatory)
        }

        // Attempt optional [.,]\d+ and check trailing \b at the extended position.
        // Python's greedy engine tries the optional first; if trailing \b fails it
        // backtracks and tries the mandatory-only match.
        var matched = false
        if afterMandatory < v.endIndex &&
           (v[afterMandatory].value == 0x2E /* . */ || v[afterMandatory].value == 0x2C /* , */) {
            let afterSep = v.index(after: afterMandatory)
            if afterSep < v.endIndex && isDigit(v[afterSep]) {
                var afterOptional = afterSep
                while afterOptional < v.endIndex && isDigit(v[afterOptional]) {
                    afterOptional = v.index(after: afterOptional)
                }
                // If the extended match satisfies trailing \b, use it.
                if isWBEnd(v, at: afterOptional) {
                    count += 1
                    i = afterOptional
                    matched = true
                }
                // Otherwise fall through to the mandatory-only boundary check below.
                // This is the Python backtrack: optional consumed but \b failed → try without.
            }
            // If no digit follows separator, optional cannot be consumed; fall through.
        }

        if !matched {
            // Mandatory-only trailing \b check (after optional backtrack or when no
            // optional separator exists).
            if isWBEnd(v, at: afterMandatory) {
                count += 1
                i = afterMandatory
            } else {
                // Neither form satisfies the trailing boundary (e.g. "01T").
                i = v.index(after: i)
            }
        }
    }
    return count
}

// MARK: - countEmail
// Python:
//   EMAIL = re.compile(r"\b[^\s@]+@[^\s@]+\.[^\s@]+\b")
//   email_mentions = len(EMAIL.findall(content))
//
// [^\s@] matches any character that is not ASCII whitespace and not '@'.
// The trailing \b requires the last matched character to be \w and the
// following character to be \W (or end of string).
//
// Python's backtracking within the final [^\s@]+ is emulated: we greedily
// consume all domain characters, then trim trailing non-word characters until
// a valid word boundary is found.  This matches "user@example.com" even when
// followed by a period or closing parenthesis.

/// True for [^\s@]: any scalar that is not ASCII whitespace and not '@'.
@inline(__always)
private func isEmailChar(_ s: Unicode.Scalar) -> Bool {
    !isWS(s) && s.value != 0x40 /* @ */
}

/// Counts all non-overlapping EMAIL matches in `content`.
///
/// Mirrors `len(EMAIL.findall(content))` in record_shape_classifier.py.
private func countEmail(_ content: String) -> Int {
    let v = content.unicodeScalars
    var count = 0
    var i = v.startIndex

    while i < v.endIndex {
        // \b requires a word-boundary start.  Since [^\s@] can include non-word
        // chars, the pattern's leading \b means the char at `i` must be a \w
        // (because the position is \W→\w).  Non-word-char leads cannot start
        // an email under this constraint.
        guard isWordChar(v[i]) && isWBStart(v, at: i) else {
            i = v.index(after: i)
            continue
        }

        if let end = tryEmail(v, from: i) {
            count += 1
            i = end
        } else {
            i = v.index(after: i)
        }
    }
    return count
}

/// Attempts to match the EMAIL pattern starting at `i`.
/// Returns the end index of the match (satisfying trailing \b), or nil.
///
/// The function finds the last '.' in the domain portion that splits a
/// non-empty subdomain from a non-empty TLD, then trims trailing non-word
/// characters to satisfy \b.  This replicates Python's backtracking over
/// `[^\s@]+\.[^\s@]+`.
private func tryEmail(
    _ v: String.UnicodeScalarView,
    from i: String.UnicodeScalarView.Index
) -> String.UnicodeScalarView.Index? {
    var j = i

    // [^\s@]+: local part — one or more non-whitespace non-@ chars
    guard j < v.endIndex && isEmailChar(v[j]) else { return nil }
    while j < v.endIndex && isEmailChar(v[j]) { j = v.index(after: j) }

    // '@'
    guard j < v.endIndex && v[j].value == 0x40 else { return nil }
    j = v.index(after: j)

    // [^\s@]+\.[^\s@]+: domain portion with at least one internal dot
    let domainStart = j
    guard j < v.endIndex && isEmailChar(v[j]) else { return nil }
    while j < v.endIndex && isEmailChar(v[j]) { j = v.index(after: j) }
    let domainEnd = j

    // Find the last '.' in the domain that has at least one char before and after it.
    // This replicates Python's greedy [^\s@]+ backtracking to split domain from TLD.
    var lastDotIdx: String.UnicodeScalarView.Index? = nil
    var k = domainStart
    while k < domainEnd {
        if v[k].value == 0x2E /* . */ {
            // Require non-empty domain before this dot and non-empty TLD after.
            if k > domainStart && v.index(after: k) < domainEnd {
                lastDotIdx = k
            }
        }
        k = v.index(after: k)
    }
    guard let dotIdx = lastDotIdx else { return nil }

    // TLD starts immediately after the dot.
    let tldStart = v.index(after: dotIdx)
    guard tldStart < domainEnd else { return nil }  // TLD must be non-empty

    // Trim trailing non-word characters from the greedy match.
    // Python backtracks [^\s@]+ until \b is satisfied; we replicate this by
    // shrinking `end` until the character at `end-1` is a word char.
    var end = domainEnd
    while end > tldStart {
        let prev = v.index(before: end)
        if isWordChar(v[prev]) { break }
        end = prev
    }
    guard end > tldStart else { return nil }

    // Verify trailing \b: last char (at end-1) must be word, char at end non-word.
    guard isWordChar(v[v.index(before: end)]) && isWBEnd(v, at: end) else { return nil }

    return end
}

// MARK: - _pct
// Python: def _pct(numerator, denominator): return 0 if denominator <= 0 else numerator * 100 // denominator
//
// Python // is floor division.  For non-negative integer operands, Swift's /
// (truncating toward zero) produces the same result.

/// Integer percentage: `numerator * 100 / denominator`.
/// Returns 0 when denominator ≤ 0.  Mirrors `_pct` in record_shape_classifier.py.
@inline(__always)
private func pct(_ numerator: Int, _ denominator: Int) -> Int {
    denominator <= 0 ? 0 : numerator * 100 / denominator
}

// MARK: - Public API

/// Entry point for structural topology classification.
///
/// All methods are pure functions.  No shared state, no Date(), no randomness.
public enum ContextShape {

    // MARK: nuextract_method_order
    // Mirrors nuextract_method_order(decision) in distill_plus_converter.py.
    // Harness-facing: used to rank same-model NuExtract templates.

    /// Ranks same-model NuExtract templates from structural evidence.
    ///
    /// Mirrors `nuextract_method_order(decision)` in distill_plus_converter.py.
    /// Marked harness-facing; not used in the classification oracle itself.
    public static func nuextractMethodOrder(_ decision: ShapeDecision) -> [String] {
        if decision.has("timeline") {
            return ["timeline", "documentary", "conversation", "compact"]
        }
        // Documentary evidence wins hybrid records with outlines/timelines;
        // the conversation template remains the deterministic second attempt.
        let documentaryScore = max(
            decision.scores["timeline", default: 0],
            decision.scores["outline", default: 0],
            decision.scores["entity_dense", default: 0],
            decision.scores["prose", default: 0]
        )
        let dialogueScore = decision.scores["dialogue", default: 0]
        let firstTwo = dialogueScore > documentaryScore
            ? ["conversation", "documentary"]
            : ["documentary", "conversation"]
        // The compact scalar template is a final same-model method for short or
        // thin documents; policy may omit it for long inputs.
        return firstTwo + ["compact"]
    }

    // MARK: qwen3_method_order
    // Mirrors qwen3_method_order(decision) in distill_plus_converter.py.
    // Harness-facing: used to rank same-model Qwen3 framings.

    /// Ranks same-model Qwen3 framings from structural evidence.
    ///
    /// Mirrors `qwen3_method_order(decision)` in distill_plus_converter.py.
    /// Marked harness-facing; not used in the classification oracle itself.
    public static func qwen3MethodOrder(_ decision: ShapeDecision) -> [String] {
        let repetitive = ["dialogue", "timeline", "outline", "hybrid"].contains { decision.has($0) }
        let firstTwo = repetitive ? ["reframed", "standard"] : ["standard", "reframed"]
        if decision.has("dialogue") &&
           decision.scores["dialogue", default: 0] > decision.scores["outline", default: 0] {
            return [firstTwo[0], "dialogue_facts", firstTwo[1], "json_chunks"]
        }
        return firstTwo + ["json_chunks"]
    }

    // MARK: classify

    /// Classifies the structural topology of `content` without using corpus or
    /// outcome knowledge.
    ///
    /// A faithful port of `classify_record(content: str) -> ShapeDecision` from
    /// record_shape_classifier.py.  Every computation uses integer arithmetic
    /// to match the Python reference byte-for-byte.  No regex engine is used;
    /// all pattern matching is done via hand-written Unicode-scalar scanners.
    ///
    /// - Parameter content: The raw source text of an estate record.
    ///   Corresponds to Python's `content: str` argument.
    /// - Returns: A ``ShapeDecision`` whose ``features``, ``scores``, ``labels``,
    ///   ``primary``, and ``confidenceMargin`` fields match the oracle JSONL vectors
    ///   exactly when serialised to canonical JSON.
    public static func classify(_ content: String) -> ShapeDecision {

        // lines = [line for line in content.splitlines() if line.strip()]
        // Foundation's components(separatedBy:) does not include separators,
        // matching Python's splitlines() behaviour.  An empty trailing component
        // (when content ends with \n) is filtered by the non-empty check below.
        let splitLines = content.components(separatedBy: .newlines)
        let lines = splitLines.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let lineCount = max(1, lines.count)

        // Build tags list and count known-speaker lines.
        // Mirrors: for line in lines: match = TAG_LINE.match(line)
        var tags: [String] = []
        var knownSpeakerLines = 0
        for line in lines {
            guard let (tag, _) = matchTagLine(line) else { continue }
            tags.append(tag)
            // Mirrors: if tag in KNOWN_SPEAKERS or tag.startswith("speaker ")
            if knownSpeakers.contains(tag) || tag.hasPrefix("speaker ") {
                knownSpeakerLines += 1
            }
        }

        // tag_counts = Counter(tags)
        // top2_tag_lines = sum(count for _, count in tag_counts.most_common(2))
        //
        // Counter.most_common(2) returns the two highest-count entries.
        // For ties, Python's heapq.nlargest may return either; however, summing
        // the top-2 counts is the same regardless of which tied element is chosen.
        var tagCountMap: [String: Int] = [:]
        for tag in tags { tagCountMap[tag, default: 0] += 1 }
        // Sort counts descending and sum the top two.
        let sortedCounts = tagCountMap.values.sorted(by: >)
        let top2TagLines = sortedCounts.prefix(2).reduce(0, +)

        // tag_switches = sum(1 for left, right in zip(tags, tags[1:]) if left != right)
        // zip(tags, tags[1:]) pairs each element with its successor.
        let tagSwitches = zip(tags, tags.dropFirst()).filter { $0.0 != $0.1 }.count

        // Line-based structural counts
        let dateLeadLines = lines.filter { matchDateLead($0) }.count
        let bulletLines   = lines.filter { matchBulletLead($0) }.count
        let headingLines  = lines.filter { matchHeadingLead($0) }.count

        // Pipe-split applied to raw content (not individual lines).
        // Non-empty parts only (after strip), matching Python's list comprehension.
        let pipeSegments = splitByPipe(content).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let pipePartsCount     = pipeSegments.count
        let pipeDatePartsCount = pipeSegments.filter { matchDateLead($0) }.count

        // Content-wide pattern counts (applied to the full raw content string)
        let dateMentions   = countDateAny(content)
        let numberMentions = countNumberAny(content)
        let emailMentions  = countEmail(content)

        // len(content) in Python counts Unicode code points (scalar values).
        // Swift String.unicodeScalars.count gives the same number.
        let contentLen = content.unicodeScalars.count

        // average_line_chars = len(content) // line_count
        // Python // is floor division; for non-negative Int operands, Swift / is identical.
        let averageLineChars = contentLen / lineCount

        // ── features ─────────────────────────────────────────────────────────
        // Keys and computation order match Python's features dict.
        let features: [String: Int] = [
            "chars": contentLen,
            "lines": lines.count,
            "tag_lines": tags.count,
            "distinct_tags": tagCountMap.count,
            "known_speaker_lines": knownSpeakerLines,
            "tag_line_pct":     pct(tags.count,      lineCount),
            "top2_tag_pct":     pct(top2TagLines,    tags.count),
            "tag_switch_pct":   pct(tagSwitches,     max(1, tags.count - 1)),
            "date_lead_lines": dateLeadLines,
            "date_lead_pct":    pct(dateLeadLines,   lineCount),
            "bullet_lines": bulletLines,
            "bullet_line_pct":  pct(bulletLines,     lineCount),
            "heading_lines": headingLines,
            "pipe_parts": pipePartsCount,
            "pipe_date_parts": pipeDatePartsCount,
            "date_mentions": dateMentions,
            "number_mentions": numberMentions,
            "email_mentions": emailMentions,
            "average_line_chars": averageLineChars,
        ]

        // ── scores ────────────────────────────────────────────────────────────
        // Initialise all five scores at 0, then accumulate evidence.
        var scores: [String: Int] = [
            "dialogue": 0, "timeline": 0, "outline": 0,
            "entity_dense": 0, "prose": 0,
        ]

        // Dialogue: requires repeated speaker structure, not merely colon-headed lines.
        // Known user/assistant labels are strong evidence; arbitrary character names
        // can still qualify through repetition and alternation.
        if tags.count >= 4                            { scores["dialogue"]!    += 5 }
        if features["tag_line_pct"]!   >= 25          { scores["dialogue"]!    += 2 }
        if features["top2_tag_pct"]!   >= 60          { scores["dialogue"]!    += 4 }
        if features["tag_switch_pct"]! >= 50          { scores["dialogue"]!    += 2 }
        if knownSpeakerLines >= 2                     { scores["dialogue"]!    += 4 }

        // Timeline: dated-line dominance or pipe-separated date columns.
        if dateLeadLines >= 3                         { scores["timeline"]!    += 7 }
        if features["date_lead_pct"]!  >= 25          { scores["timeline"]!    += 4 }
        if pipeDatePartsCount >= 3                    { scores["timeline"]!    += 5 }
        if dateMentions >= 5                          { scores["timeline"]!    += 2 }

        // Outline: bullet/heading density or pipe-column structure.
        if bulletLines >= 3                           { scores["outline"]!     += 7 }
        if features["bullet_line_pct"]! >= 20         { scores["outline"]!     += 4 }
        if headingLines >= 2                          { scores["outline"]!     += 4 }
        if pipePartsCount >= 5                        { scores["outline"]!     += 3 }

        // Entity-dense: high ratio of dates, numbers, and emails to content length.
        let scalarMentions = dateMentions + numberMentions + emailMentions
        if scalarMentions >= 8                        { scores["entity_dense"]! += 5 }
        // scalar_mentions * 1000 // max(1, len(content)) >= 3
        if scalarMentions * 1000 / max(1, contentLen) >= 3 { scores["entity_dense"]! += 3 }
        if emailMentions > 0                          { scores["entity_dense"]! += 2 }

        // Prose: short, long-line, or completely unstructured text.
        if lines.count <= 4                           { scores["prose"]!       += 4 }
        if averageLineChars >= 120                    { scores["prose"]!       += 3 }
        // not tags and not date_lead_lines and not bullet_lines
        if tags.isEmpty && dateLeadLines == 0 && bulletLines == 0 { scores["prose"]! += 4 }

        // ── active labels ─────────────────────────────────────────────────────
        // active = [label for label, score in scores.items() if score >= 6]
        // Note: scores is an unordered dict in both Python and Swift; `active`
        // is only used after being sorted into `ranked`, so initial order is irrelevant.
        var active = scores.filter { $0.value >= 6 }.map { $0.key }

        // structural = [label for label in ("dialogue","timeline","outline") if label in active]
        // Computed BEFORE the fallback so it reflects the un-modified active set.
        let structuralOrder = ["dialogue", "timeline", "outline"]
        let structural = structuralOrder.filter { active.contains($0) }

        // if not active: active = ["prose"]
        if active.isEmpty { active = ["prose"] }

        // ranked = sorted(active, key=lambda label: (-scores[label], label))
        // Stable sort: ties in score → alphabetical by label name.
        let ranked = active.sorted { a, b in
            let sa = scores[a, default: 0]
            let sb = scores[b, default: 0]
            if sa != sb { return sa > sb }
            return a < b  // alphabetical tiebreaker, matching Python's tuple comparison
        }

        // Primary and labels
        let primary: String
        let labels: [String]
        if structural.count >= 2 {
            // Two or more structural categories are active simultaneously.
            primary = "hybrid"
            labels = ["hybrid"] + ranked
        } else {
            primary = ranked[0]
            labels = ranked
        }

        // confidence_margin: top score − second score across all five categories.
        // ordered_scores = sorted(scores.values(), reverse=True)
        // margin = ordered_scores[0] - ordered_scores[1]
        let orderedScores = scores.values.sorted(by: >)
        // scores always has exactly 5 entries; orderedScores always has indices 0 and 1.
        let confidenceMargin = orderedScores[0] - orderedScores[1]

        return ShapeDecision(
            primary: primary,
            labels: labels,
            scores: scores,
            features: features,
            confidenceMargin: confidenceMargin
        )
    }
}
