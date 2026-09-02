// Scanners.swift
// Hand-written scanners for all 26 compiled regex constants in
// distill_plus_converter.py, plus the 4 from record_shape_classifier.py
// used in the intent path.
//
// IMPORTANT: NO regex engine is used anywhere in this file.
// NSRegularExpression, Swift Regex, and the regex crate are all forbidden.
// Each scanner is a state machine that mirrors Python Unicode semantics.
//
// Reference patterns (verbatim from distill_plus_converter.py):
//   TRAILER_RE           = r"(?P<trailer>\s+\(\*\[\s.*?\s\]\*\))\s*$"  (re.DOTALL)
//   PIPE_SPLIT_RE        = r"\s+\|\s+"
//   INLINE_NUMBERED_RE   = r"(?:^|\s)(?P<marker>\d+[.)]\s+)"
//   LIST_MARKER_RE       = r"^\s*(?:[-*+•]|\d+[.)])\s+"
//   WORD_RE              = r"[A-Za-z0-9]+(?:['-][A-Za-z0-9]+)*"
//   NUMBER_RE            = r"\b\d+(?:[.,]\d+)?\b"
//   DATE_RE              = r"\b(?:\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2})?)?|\d{1,2}[/-]\d{1,2}[/-]\d{2,4}|\d{4})\b"
//   CAPITALIZED_RE       = r"\b[A-Z][A-Za-z0-9_-]+\b"
//   GREETING_PREFIX_RE   = r"^\s*(?:(?:hi|hello|hey|good morning|good afternoon|good evening)(?:\s+there)?[!,.\s]*|(?:thanks|thank you)(?:\s+so much)?[!,.\s]+)"  (re.IGNORECASE)
//   GREETING_ONLY_RE     = r"^\s*(?:hi|hello|hey|good morning|good afternoon|good evening|thanks|thank you|bye|goodbye)(?:\s+(?:there|for now|so much))?[!,.\s]*$"  (re.IGNORECASE)
//   DIALOGUE_FILLER_ONLY_RE = r"^\s*(?:exactly|precisely|absolutely|sure|right|okay|ok|oh[, ]+tell me about it|that(?:'s| is) (?:great|wonderful|lovely|fantastic)(?: to hear)?)[!.\s]*$"  (re.IGNORECASE)
//   REVISION_MARKER_RE   = r"\b(?:revised|updated|final)\s+(?:chapter\s+)?(?:outline|draft|plan|version)\b"  (re.IGNORECASE)
//   INITIAL_DRAFT_MARKER_RE = r"\b(?:first|initial|original)\s+(?:chapter\s+)?(?:outline|draft|plan|version)\b"  (re.IGNORECASE)
//   OPERATIVE_RE         = r"^\s*(?:please\s+)?(?:amend|analy[sz]e|answer|check|compare|convert|describe|determine|edit|explain|extract|find|identify|list|review|revise|show|summarize|tell|update|verify|write)\b"  (re.IGNORECASE)
//   TURN_FILLER_RE       = r"^\s*(?:acknowledged|noted|received|ok(?:ay)?|sure|thanks|thank you|got it|understood|sounds good|great|perfect|exactly|absolutely|you(?:'re| are) welcome)[.!\s]*$"  (re.IGNORECASE)
//   ASSISTANT_BOILERPLATE_RE = r"^\s*(?:certainly|sure|of course)[.!,:\s]*(?:i(?:'d| will) be happy to)?\s*$|^\s*i hope this helps[.!?\s]*$|^\s*let me know if you (?:have|need)(?: any)? (?:questions|anything(?: else)?)[.!?\s]*$"  (re.IGNORECASE|re.DOTALL)
//   EMBEDDED_USER_FACT_RE = r"(?:^|\n).*?(?P<fact>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}[^\n]*?\s[—-]\s*user:\s*[^\n]+)"  (re.IGNORECASE)
//   FENCE_OPEN_RE        = r"^\s*(`{3,}|~{3,})"
//   MARKDOWN_HEADING_RE  = r"^(?P<marks>#{1,6})\s+\S"
//   BOLD_HEADING_RE      = r"^\s*\*\*[^*\n]{1,120}\*\*\s*:?[ \t]*$"
//   FIELD_LINE_RE        = r"^\s*[A-Za-z][A-Za-z0-9 _./()-]{0,80}:\s*\S"
//   TABLE_SEPARATOR_RE   = r"^\s*\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)+\|?\s*$"
//   DIAGRAM_RE           = r"[─-╿]|(?:--?>|==>|<--?)"
//   POLARITY_ONLY_RE     = r"^\s*(?:yes|no)\b[.!?\s]*$"  (re.IGNORECASE)
//   TRANSFORM_FOLLOWUP_RE = r"\b(?:adapt|convert|make|port|rewrite|translate|turn)\b[^\n]{0,120}\b(?:answer|code|example|function|it|that|this)\b|\b(?:answer|code|example|function|it|that|this)\b[^\n]{0,120}\b(?:adapt|convert|make|port|rewrite|translate|turn)\b"  (re.IGNORECASE)
//   QUANTITY_VALUE_RE    = r"^[€£$]?\d+(?:[.,]\d+)?(?:\s+[A-Za-z%][A-Za-z0-9%._/-]*){0,3}$"
//
// Unicode index unit: code points (Python str indices).
// Swift uses unicodeScalars; Rust uses chars().

import Foundation

// MARK: - MatchResult

/// A single scanner match: start/end code-point positions and captured groups.
///
/// Mirrors the `(start, end, groups)` triple that gen_scanner_vectors.py
/// records for each `finditer` match.
///
/// - `start`: inclusive code-point index of the match start.
/// - `end`: exclusive code-point index of the match end.
/// - `groups`: captured-group strings in declaration order; `nil` when a
///   group did not participate in the match (Python `None`).
public struct MatchResult: Sendable, Equatable {
    public let start: Int
    public let end: Int
    public let groups: [String?]

    public init(start: Int, end: Int, groups: [String?]) {
        self.start = start
        self.end = end
        self.groups = groups
    }
}

// MARK: - Internal ASCII helpers

/// Returns `true` if `v` is an ASCII digit (0x30–0x39).
@inline(__always)
private func isASCIIDigit(_ v: UInt32) -> Bool { v >= 0x30 && v <= 0x39 }

/// Returns `true` if `v` is an ASCII uppercase letter (0x41–0x5A).
@inline(__always)
private func isASCIIUpper(_ v: UInt32) -> Bool { v >= 0x41 && v <= 0x5A }

/// Returns `true` if `v` is an ASCII lowercase letter (0x61–0x7A).
@inline(__always)
private func isASCIILower(_ v: UInt32) -> Bool { v >= 0x61 && v <= 0x7A }

/// Returns `true` if `v` is an ASCII letter.
@inline(__always)
private func isASCIIAlpha(_ v: UInt32) -> Bool { isASCIIUpper(v) || isASCIILower(v) }

/// Returns `true` if `v` is an ASCII alphanumeric character.
@inline(__always)
private func isASCIIAlnum(_ v: UInt32) -> Bool { isASCIIAlpha(v) || isASCIIDigit(v) }

/// Returns `true` if `v` is an ASCII word character: alnum or underscore.
@inline(__always)
private func isASCIIWordChar(_ v: UInt32) -> Bool { isASCIIAlnum(v) || v == 0x5F }

/// Converts ASCII letter scalar to its lowercase value; non-letters unchanged.
@inline(__always)
private func asciiToLower(_ v: UInt32) -> UInt32 {
    isASCIIUpper(v) ? v + 32 : v
}

/// Case-insensitive ASCII comparison of two scalar values.
@inline(__always)
private func asciiEqCI(_ a: UInt32, _ b: UInt32) -> Bool {
    asciiToLower(a) == asciiToLower(b)
}

// MARK: - Word-boundary helper (Python \b, ASCII-optimised for most patterns)

/// Python-semantic word boundary at `index` using `isPythonWordChar`.
///
/// Most scanner patterns use ASCII word characters only.  The full Unicode
/// `\b` check is used for patterns where `isPythonWordChar` matters (e.g.
/// REVISION_MARKER_RE applied to Unicode text).
private func asciiWordBoundary(at index: Int, in scalars: [Unicode.Scalar]) -> Bool {
    let prevW: Bool = index > 0 && isASCIIWordChar(scalars[index - 1].value)
    let currW: Bool = index < scalars.count && isASCIIWordChar(scalars[index].value)
    return prevW != currW
}

// MARK: - TRAILER_RE
// Pattern: (?P<trailer>\s+\(\*\[\s.*?\s\]\*\))\s*$   (re.DOTALL)
//
// DOTALL means .* also matches \n.  Non-greedy .*? finds the leftmost (*[...]*)
// after leading whitespace.  The $ anchors to end of string.
//
// This is a search (finds first occurrence).  finditer returns 0 or 1 matches.
// The captured group ("trailer") is the entire matched span including leading \s+.
//
// Used by splitEnrichment() in Digest.swift.

/// Search for TRAILER_RE in `scalars`.  Returns the first match or `nil`.
///
/// Mirrors Python's `TRAILER_RE.search(distilled)`.
public func trailerRESearch(_ scalars: [Unicode.Scalar]) -> MatchResult? {
    // We look for the pattern: \s+ (*[ \s.*?\s ]*) \s*$
    // Since DOTALL, .* matches anything including \n.
    // Non-greedy: find the leftmost (*[...]*).
    // Strategy: scan for \s+(*[ prefix, then scan lazily to \s]*) suffix,
    // then confirm \s*$ after the match.

    let n = scalars.count
    var i = 0
    while i < n {
        // Must start with at least one Python whitespace char.
        guard isPythonWhitespace(scalars[i]) else { i += 1; continue }
        let matchStart = i
        // Consume the \s+ run.
        var j = i + 1
        while j < n && isPythonWhitespace(scalars[j]) { j += 1 }
        // Now expect "(*[" (literal).
        guard j + 3 <= n,
              scalars[j].value == 0x28,   // (
              scalars[j + 1].value == 0x2A, // *
              scalars[j + 2].value == 0x5B  // [
        else { i += 1; continue }
        j += 3  // consumed (*[
        // Expect one \s (the \s before .*? in \s.*?\s inside the trailer).
        guard j < n && isPythonWhitespace(scalars[j]) else { i += 1; continue }
        j += 1
        // Non-greedy .*? followed by \s]*).
        // Scan for the FIRST occurrence of \s]*) from position j.
        var found = false
        while j < n {
            // Check for \s ]*) at current position j.
            if isPythonWhitespace(scalars[j]),
               j + 3 < n,
               scalars[j + 1].value == 0x5D, // ]
               scalars[j + 2].value == 0x2A, // *
               scalars[j + 3].value == 0x29  // )
            {
                let trailerEnd = j + 4
                // Now check \s*$ (only Python whitespace, then end of string).
                var k = trailerEnd
                while k < n && isPythonWhitespace(scalars[k]) { k += 1 }
                if k == n {
                    // Full match from matchStart to trailerEnd.
                    // Group 0 ("trailer") = the captured group = matchStart ... trailerEnd.
                    let groupText = scalars[matchStart ..< trailerEnd].asString()
                    found = true
                    return MatchResult(
                        start: matchStart,
                        end: k, // includes trailing \s*
                        groups: [groupText]
                    )
                }
            }
            j += 1
        }
        if !found { i += 1 }
    }
    return nil
}

/// finditer for TRAILER_RE.  Returns 0 or 1 matches (single `$`-anchored pattern).
public func trailerREFinditer(_ scalars: [Unicode.Scalar]) -> [MatchResult] {
    if let m = trailerRESearch(scalars) { return [m] }
    return []
}

// MARK: - PIPE_SPLIT_RE
// Pattern: \s+\|\s+
// No anchors, no groups.  Finds all runs of whitespace-|-whitespace.

/// finditer for PIPE_SPLIT_RE.
public func pipeSplitREFinditer(_ scalars: [Unicode.Scalar]) -> [MatchResult] {
    var results: [MatchResult] = []
    let n = scalars.count
    var i = 0
    while i < n {
        guard isPythonWhitespace(scalars[i]) else { i += 1; continue }
        let start = i
        while i < n && isPythonWhitespace(scalars[i]) { i += 1 }
        guard i < n && scalars[i].value == 0x7C else { continue } // |
        i += 1
        guard i < n && isPythonWhitespace(scalars[i]) else { continue }
        while i < n && isPythonWhitespace(scalars[i]) { i += 1 }
        results.append(MatchResult(start: start, end: i, groups: []))
    }
    return results
}

// MARK: - INLINE_NUMBERED_RE
// Pattern: (?:^|\s)(?P<marker>\d+[.)]\s+)
//
// The non-capturing group (?:^|\s) consumes the preceding whitespace or is
// zero-width at position 0.  The captured group "marker" = digits + separator
// + trailing whitespace.
//
// Python finditer returns matches that include the \s before the marker.
// Group 1 (index 0) is the "marker" group.

/// finditer for INLINE_NUMBERED_RE.
public func inlineNumberedREFinditer(_ scalars: [Unicode.Scalar]) -> [MatchResult] {
    var results: [MatchResult] = []
    let n = scalars.count
    var i = 0
    while i < n {
        // Anchor: position 0 OR current char is whitespace.
        let atAnchor = (i == 0) || isPythonWhitespace(scalars[i])
        guard atAnchor else { i += 1; continue }
        // The match start: position of the anchor char (or 0).
        let matchStart = i
        // Skip the whitespace char if we consumed it (not at position 0 with ^).
        var j = (i == 0 && !isPythonWhitespace(scalars[i])) ? i : i + 1
        // At position 0 with '^' anchor: j stays at 0.
        if i == 0 && !isPythonWhitespace(scalars[i]) {
            j = 0
        } else if i == 0 && isPythonWhitespace(scalars[i]) {
            // ^ matches here, but so does \s — Python tries ^ first.
            // At i==0 with whitespace, the pattern (?:^|\s) matches ^ (zero-width).
            // So j = i = 0 for the ^ branch.
            // But ALSO when i==0 and it's whitespace, the \s branch also anchors here.
            // Python's re tries ^ first (zero-width), so the match starts at i=0.
            j = 0
        } else {
            // i > 0 and scalars[i] is whitespace: match includes the \s char.
            j = i + 1
        }
        // j now points to the start of the potential marker.
        guard j < n && isASCIIDigit(scalars[j].value) else { i += 1; continue }
        let markerStart = j
        while j < n && isASCIIDigit(scalars[j].value) { j += 1 }
        // Expect [.)]: period or right-paren.
        guard j < n && (scalars[j].value == 0x2E || scalars[j].value == 0x29)
        else { i += 1; continue }
        j += 1
        // Expect \s+.
        guard j < n && isPythonWhitespace(scalars[j]) else { i += 1; continue }
        while j < n && isPythonWhitespace(scalars[j]) { j += 1 }
        // Group "marker" = markerStart..j (digits + sep + whitespace).
        let markerText = scalars[markerStart ..< j].asString()
        results.append(MatchResult(
            start: matchStart,
            end: j,
            groups: [markerText]
        ))
        // Advance past the consumed whitespace anchor (not re-use).
        i = j
    }
    return results
}

// MARK: - LIST_MARKER_RE
// Pattern: ^\s*(?:[-*+•]|\d+[.)])\s+
// Anchored at ^. No MULTILINE. Returns 0 or 1 match on the full text.

/// finditer for LIST_MARKER_RE.
public func listMarkerREFinditer(_ scalars: [Unicode.Scalar]) -> [MatchResult] {
    let n = scalars.count
    var i = 0
    // Skip leading whitespace.
    while i < n && isPythonWhitespace(scalars[i]) { i += 1 }
    guard i < n else { return [] }
    let v = scalars[i].value
    // Unordered bullet: - * + or • (U+2022).
    if v == 0x2D || v == 0x2A || v == 0x2B || v == 0x2022 {
        i += 1
        // Expect \s+.
        guard i < n && isPythonWhitespace(scalars[i]) else { return [] }
        while i < n && isPythonWhitespace(scalars[i]) { i += 1 }
        return [MatchResult(start: 0, end: i, groups: [])]
    }
    // Ordered: \d+[.)]
    if isASCIIDigit(v) {
        while i < n && isASCIIDigit(scalars[i].value) { i += 1 }
        guard i < n && (scalars[i].value == 0x2E || scalars[i].value == 0x29)
        else { return [] }
        i += 1
        guard i < n && isPythonWhitespace(scalars[i]) else { return [] }
        while i < n && isPythonWhitespace(scalars[i]) { i += 1 }
        return [MatchResult(start: 0, end: i, groups: [])]
    }
    return []
}

// MARK: - WORD_RE
// Pattern: [A-Za-z0-9]+(?:['-][A-Za-z0-9]+)*
// No anchors, no groups.  ASCII-only.

/// finditer for WORD_RE.
public func wordREFinditer(_ scalars: [Unicode.Scalar]) -> [MatchResult] {
    var results: [MatchResult] = []
    let n = scalars.count
    var i = 0
    while i < n {
        guard isASCIIAlnum(scalars[i].value) else { i += 1; continue }
        let start = i
        while i < n && isASCIIAlnum(scalars[i].value) { i += 1 }
        // Optional extension: ['-][A-Za-z0-9]+  (can repeat)
        while i < n {
            let sep = scalars[i].value
            // ['-] in Python: the - at end of character class is literal.
            // So it matches ' (0x27) or - (0x2D).
            guard (sep == 0x27 || sep == 0x2D) else { break }
            guard i + 1 < n && isASCIIAlnum(scalars[i + 1].value) else { break }
            i += 1  // consume ' or -
            while i < n && isASCIIAlnum(scalars[i].value) { i += 1 }
        }
        results.append(MatchResult(start: start, end: i, groups: []))
    }
    return results
}

// MARK: - NUMBER_RE
// Pattern: \b\d+(?:[.,]\d+)?\b
// Word boundary before and after.  ASCII digits only.  [.,] = literal . or ,.

/// finditer for NUMBER_RE.
public func numberREFinditer(_ scalars: [Unicode.Scalar]) -> [MatchResult] {
    var results: [MatchResult] = []
    let n = scalars.count
    var i = 0
    while i < n {
        // Must be a digit at a word boundary.  Python \b uses full Unicode \w;
        // digits are ASCII-only here, so the boundary check is ASCII-safe for the
        // start.  The end boundary must also use the full Unicode-aware check
        // because the char AFTER the number may be a Unicode letter (e.g. "183m").
        guard isASCIIDigit(scalars[i].value)
              && pyWordBoundary(at: i, in: scalars)
        else { i += 1; continue }
        let start = i
        while i < n && isASCIIDigit(scalars[i].value) { i += 1 }
        let afterDigits = i  // position after the mandatory \d+ part

        // Optional decimal part: [.,] followed by one or more digits.
        // Greedy: try with decimal first; backtrack to afterDigits if \b fails.
        if i < n && (scalars[i].value == 0x2E || scalars[i].value == 0x2C)
           && i + 1 < n && isASCIIDigit(scalars[i + 1].value)
        {
            i += 1  // consume . or ,
            while i < n && isASCIIDigit(scalars[i].value) { i += 1 }
            // Check word boundary after the full number including decimal.
            if !pyWordBoundary(at: i, in: scalars) {
                // Decimal part consumed but \b fails — backtrack to integer-only match.
                i = afterDigits
            }
        }

        // Re-check boundary at the current end position (after possible backtrack).
        guard pyWordBoundary(at: i, in: scalars) else { i = afterDigits; continue }
        results.append(MatchResult(start: start, end: i, groups: []))
    }
    return results
}

// MARK: - DATE_RE
// Pattern: \b(?:\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2})?)?|\d{1,2}[/-]\d{1,2}[/-]\d{2,4}|\d{4})\b
// Three alternatives tried left-to-right.  Word boundaries at start/end.
// No capturing groups.

/// Attempts to match alt-1 of DATE_RE at `i`: `\d{4}-\d{2}-\d{2}(...)?`.
/// Returns end position or nil.
private func matchDateAlt1(_ s: [Unicode.Scalar], at i: Int) -> Int? {
    let n = s.count
    guard i + 10 <= n else { return nil }
    // \d{4}
    guard (0..<4).allSatisfy({ isASCIIDigit(s[i + $0].value) }) else { return nil }
    guard s[i + 4].value == 0x2D else { return nil }  // -
    guard isASCIIDigit(s[i + 5].value) && isASCIIDigit(s[i + 6].value) else { return nil }
    guard s[i + 7].value == 0x2D else { return nil }  // -
    guard isASCIIDigit(s[i + 8].value) && isASCIIDigit(s[i + 9].value) else { return nil }
    var end = i + 10
    // Optional T\d{2}:\d{2}(:\d{2})?
    if end < n && s[end].value == 0x54 /* T */ {
        guard end + 6 <= n else { return end }
        guard isASCIIDigit(s[end + 1].value) && isASCIIDigit(s[end + 2].value) else { return end }
        guard s[end + 3].value == 0x3A else { return end }  // :
        guard isASCIIDigit(s[end + 4].value) && isASCIIDigit(s[end + 5].value) else { return end }
        end += 6
        // Optional :\d{2}
        if end < n && s[end].value == 0x3A && end + 3 <= n
           && isASCIIDigit(s[end + 1].value) && isASCIIDigit(s[end + 2].value)
        {
            end += 3
        }
    }
    return end
}

/// Attempts to match alt-2 of DATE_RE at `i`: `\d{1,2}[/-]\d{1,2}[/-]\d{2,4}`.
/// Returns end position or nil.
private func matchDateAlt2(_ s: [Unicode.Scalar], at i: Int) -> Int? {
    let n = s.count
    guard i < n && isASCIIDigit(s[i].value) else { return nil }
    var j = i + 1
    if j < n && isASCIIDigit(s[j].value) { j += 1 }  // second digit (optional)
    guard j < n && (s[j].value == 0x2F || s[j].value == 0x2D) else { return nil } // / or -
    j += 1
    guard j < n && isASCIIDigit(s[j].value) else { return nil }
    j += 1
    if j < n && isASCIIDigit(s[j].value) { j += 1 }  // second digit (optional)
    guard j < n && (s[j].value == 0x2F || s[j].value == 0x2D) else { return nil }
    j += 1
    // \d{2,4}
    guard j < n && isASCIIDigit(s[j].value) else { return nil }
    j += 1
    guard j < n && isASCIIDigit(s[j].value) else { return nil }
    j += 1
    // Two more optional digits for {2,4}.
    if j < n && isASCIIDigit(s[j].value) {
        j += 1
        if j < n && isASCIIDigit(s[j].value) { j += 1 }
    }
    return j
}

/// finditer for DATE_RE.
public func dateREFinditer(_ scalars: [Unicode.Scalar]) -> [MatchResult] {
    var results: [MatchResult] = []
    let n = scalars.count
    var i = 0
    while i < n {
        // Must be a digit at a word boundary.
        guard isASCIIDigit(scalars[i].value)
              && asciiWordBoundary(at: i, in: scalars)
        else { i += 1; continue }
        // Try alt-1 first (longest, YYYY-MM-DD...).
        if let end = matchDateAlt1(scalars, at: i), asciiWordBoundary(at: end, in: scalars) {
            results.append(MatchResult(start: i, end: end, groups: []))
            i = end
            continue
        }
        // Try alt-2 (M/D/YY or M-D-YYYY).
        if let end = matchDateAlt2(scalars, at: i), asciiWordBoundary(at: end, in: scalars) {
            results.append(MatchResult(start: i, end: end, groups: []))
            i = end
            continue
        }
        // Try alt-3: exactly 4 digits with word boundary at end.
        let j4 = i + 4
        if j4 <= n && (0..<4).allSatisfy({ isASCIIDigit(scalars[i + $0].value) })
           && asciiWordBoundary(at: j4, in: scalars)
        {
            results.append(MatchResult(start: i, end: j4, groups: []))
            i = j4
            continue
        }
        i += 1
    }
    return results
}

// MARK: - CAPITALIZED_RE
// Pattern: \b[A-Z][A-Za-z0-9_-]+\b
// Word boundary, uppercase letter, then one or more alnum/underscore/hyphen.
// The + means at least ONE more char after the leading uppercase, so minimum 2.

/// finditer for CAPITALIZED_RE.
public func capitalizedREFinditer(_ scalars: [Unicode.Scalar]) -> [MatchResult] {
    var results: [MatchResult] = []
    let n = scalars.count
    var i = 0
    while i < n {
        // CAPITALIZED_RE: \b[A-Z][A-Za-z0-9_-]+\b
        //
        // Python \b uses FULL Unicode \w semantics, not ASCII-only.  A Unicode
        // letter like 'ñ' is \w in Python, so "Española" has no \b between 'E'
        // and 's' (both Unicode word chars) or between 's' and 'ñ'.  We must use
        // pyWordBoundary (which calls isPythonWordChar) to avoid false positives
        // inside Unicode words.
        //
        // The character class [A-Z] is ASCII-only; [A-Za-z0-9_-] is ASCII-only.
        // So the START must be an ASCII uppercase letter at a Python word boundary.
        guard isASCIIUpper(scalars[i].value) && pyWordBoundary(at: i, in: scalars)
        else { i += 1; continue }
        let start = i
        i += 1
        // One or more [A-Za-z0-9_-].
        guard i < n else { continue }
        let afterFirst = i  // position to reset to on failure
        let sv = scalars[i].value
        guard isASCIIAlnum(sv) || sv == 0x5F || sv == 0x2D else {
            // Only a single uppercase letter — no second char; skip.
            continue
        }
        i += 1
        while i < n {
            let v = scalars[i].value
            if isASCIIAlnum(v) || v == 0x5F || v == 0x2D { i += 1 } else { break }
        }
        // Trailing hyphens break the trailing \b because `-` is not \w in Python.
        // Back up over them to find the actual end position where \b can fire.
        // Note: `_` (0x5F) IS a Python word char, `-` (0x2D) is NOT.
        while i > afterFirst && scalars[i - 1].value == 0x2D { i -= 1 }
        // Confirm the match ends at a Python word boundary and has at least 2 chars.
        guard i > start + 1 && pyWordBoundary(at: i, in: scalars) else {
            i = afterFirst  // skip past the uppercase letter and retry
            continue
        }
        results.append(MatchResult(start: start, end: i, groups: []))
    }
    return results
}

// MARK: - GREETING_PREFIX_RE  (re.IGNORECASE)
// Pattern: ^\s*(?:(?:hi|hello|hey|good morning|good afternoon|good evening)
//           (?:\s+there)?[!,.\s]*|(?:thanks|thank you)(?:\s+so much)?[!,.\s]+)
// Anchored at ^.  Returns 0 or 1 match.

/// Returns `true` and advances `i` if the ASCII word at `scalars[i]` matches
/// `word` case-insensitively.
private func matchWordCI(
    _ scalars: [Unicode.Scalar], at i: inout Int, _ word: String
) -> Bool {
    let chars = word.unicodeScalars.map(\.value)
    guard i + chars.count <= scalars.count else { return false }
    for (j, c) in chars.enumerated() {
        guard asciiEqCI(scalars[i + j].value, c) else { return false }
    }
    i += chars.count
    return true
}

/// finditer for GREETING_PREFIX_RE.
public func greetingPrefixREFinditer(_ scalars: [Unicode.Scalar]) -> [MatchResult] {
    let n = scalars.count
    var i = 0
    // Skip leading \s*.
    while i < n && isPythonWhitespace(scalars[i]) { i += 1 }
    // Try greeting words.
    var matchedGreeting = false
    var needTrailingPunct = false  // true for thanks/thank you branch
    let greetings1 = ["good morning", "good afternoon", "good evening",
                      "hello", "hey", "hi"]  // longer first for greedy prefix
    let greetings2 = ["thank you", "thanks"]
    for g in greetings1 {
        var j = i
        if matchWordCI(scalars, at: &j, g) {
            i = j
            matchedGreeting = true
            break
        }
    }
    if !matchedGreeting {
        for g in greetings2 {
            var j = i
            if matchWordCI(scalars, at: &j, g) {
                i = j
                matchedGreeting = true
                needTrailingPunct = true
                break
            }
        }
    }
    guard matchedGreeting else { return [] }
    // For non-thanks branch: optional (\s+there).
    if !needTrailingPunct {
        var j = i
        let wsStart = j
        while j < n && isPythonWhitespace(scalars[j]) { j += 1 }
        if j > wsStart {
            var k = j
            if matchWordCI(scalars, at: &k, "there") {
                i = k
            }
            // If "there" didn't match, ws was not consumed (backtrack).
        }
        // [!,.\s]* — consume any punctuation/whitespace.
        while i < n {
            let v = scalars[i].value
            if isPythonWhitespace(scalars[i]) || v == 0x21 || v == 0x2C || v == 0x2E {
                i += 1
            } else { break }
        }
        return [MatchResult(start: 0, end: i, groups: [])]
    } else {
        // thanks/thank you branch: optional (\s+so much).
        var j = i
        let wsStart = j
        while j < n && isPythonWhitespace(scalars[j]) { j += 1 }
        if j > wsStart {
            var k = j
            if matchWordCI(scalars, at: &k, "so much") { i = k } // consumed ws + "so much"
            // else backtrack ws
        }
        // [!,.\s]+  — must have at least one punctuation/whitespace char.
        let punctStart = i
        while i < n {
            let v = scalars[i].value
            if isPythonWhitespace(scalars[i]) || v == 0x21 || v == 0x2C || v == 0x2E {
                i += 1
            } else { break }
        }
        guard i > punctStart else { return [] }
        return [MatchResult(start: 0, end: i, groups: [])]
    }
}

// MARK: - GREETING_ONLY_RE  (re.IGNORECASE)
// Pattern: ^\s*(?:hi|hello|hey|good morning|good afternoon|good evening|
//           thanks|thank you|bye|goodbye)(?:\s+(?:there|for now|so much))?[!,.\s]*$
// Anchored at ^ and $.  Returns 0 or 1 match (whole string).

/// finditer for GREETING_ONLY_RE.
public func greetingOnlyREFinditer(_ scalars: [Unicode.Scalar]) -> [MatchResult] {
    let n = scalars.count
    var i = 0
    while i < n && isPythonWhitespace(scalars[i]) { i += 1 }
    let greetings = ["good morning", "good afternoon", "good evening",
                     "thank you", "goodbye",
                     "hello", "thanks", "bye", "hey", "hi"]
    var matched = false
    for g in greetings {
        var j = i
        if matchWordCI(scalars, at: &j, g) { i = j; matched = true; break }
    }
    guard matched else { return [] }
    // Optional (\s+ (there|for now|so much)).
    var j = i
    let wsStart = j
    while j < n && isPythonWhitespace(scalars[j]) { j += 1 }
    if j > wsStart {
        var k = j
        let suffixes = ["for now", "so much", "there"]
        var suffixMatched = false
        for suf in suffixes {
            k = j
            if matchWordCI(scalars, at: &k, suf) { i = k; suffixMatched = true; break }
        }
        if !suffixMatched {
            // Back up: don't consume the whitespace.
        }
    }
    // [!,.\s]*
    while i < n {
        let v = scalars[i].value
        if isPythonWhitespace(scalars[i]) || v == 0x21 || v == 0x2C || v == 0x2E { i += 1 }
        else { break }
    }
    // $ — must be at end of string.
    guard i == n else { return [] }
    return [MatchResult(start: 0, end: n, groups: [])]
}

// MARK: - DIALOGUE_FILLER_ONLY_RE  (re.IGNORECASE)
// Pattern: ^\s*(?:exactly|precisely|absolutely|sure|right|okay|ok|
//           oh[, ]+tell me about it|
//           that(?:'s| is) (?:great|wonderful|lovely|fantastic)(?: to hear)?)[!.\s]*$

/// finditer for DIALOGUE_FILLER_ONLY_RE.
public func dialogueFillerOnlyREFinditer(_ scalars: [Unicode.Scalar]) -> [MatchResult] {
    let n = scalars.count
    var i = 0
    while i < n && isPythonWhitespace(scalars[i]) { i += 1 }
    // Try each alternative.
    let simpleWords = ["absolutely", "precisely", "exactly", "right", "okay", "sure", "ok"]
    var matched = false
    for w in simpleWords {
        var j = i
        if matchWordCI(scalars, at: &j, w) { i = j; matched = true; break }
    }
    if !matched {
        // oh[, ]+tell me about it
        var j = i
        if matchWordCI(scalars, at: &j, "oh") {
            // [, ]+
            var k = j
            while k < n && (scalars[k].value == 0x2C || scalars[k].value == 0x20) { k += 1 }
            if k > j && matchWordCI(scalars, at: &k, "tell me about it") {
                i = k; matched = true
            }
        }
    }
    if !matched {
        // that('s| is) (great|wonderful|lovely|fantastic)( to hear)?
        var j = i
        if matchWordCI(scalars, at: &j, "that") {
            var k = j
            if matchWordCI(scalars, at: &k, "'s") || matchWordCI(scalars, at: &k, " is") {
                while k < n && scalars[k].value == 0x20 { k += 1 }
                let feelings = ["wonderful", "fantastic", "lovely", "great"]
                var feelMatched = false
                for f in feelings {
                    var l = k
                    if matchWordCI(scalars, at: &l, f) {
                        k = l; feelMatched = true; break
                    }
                }
                if feelMatched {
                    // optional " to hear"
                    var l = k
                    if matchWordCI(scalars, at: &l, " to hear") { k = l }
                    i = k; matched = true
                }
            }
        }
    }
    guard matched else { return [] }
    // [!.\s]*
    while i < n {
        let v = scalars[i].value
        if isPythonWhitespace(scalars[i]) || v == 0x21 || v == 0x2E { i += 1 } else { break }
    }
    guard i == n else { return [] }
    return [MatchResult(start: 0, end: n, groups: [])]
}

// MARK: - REVISION_MARKER_RE  (re.IGNORECASE)
// Pattern: \b(?:revised|updated|final)\s+(?:chapter\s+)?(?:outline|draft|plan|version)\b

/// finditer for REVISION_MARKER_RE.
public func revisionMarkerREFinditer(_ scalars: [Unicode.Scalar]) -> [MatchResult] {
    var results: [MatchResult] = []
    let n = scalars.count
    var i = 0
    while i < n {
        guard asciiWordBoundary(at: i, in: scalars) else { i += 1; continue }
        var j = i
        let verbs = ["revised", "updated", "final"]
        var verbMatched = false
        for v in verbs {
            j = i
            if matchWordCI(scalars, at: &j, v) { verbMatched = true; break }
        }
        guard verbMatched else { i += 1; continue }
        // \s+
        guard j < n && isPythonWhitespace(scalars[j]) else { i += 1; continue }
        while j < n && isPythonWhitespace(scalars[j]) { j += 1 }
        // optional (chapter\s+)
        var k = j
        if matchWordCI(scalars, at: &k, "chapter") {
            if k < n && isPythonWhitespace(scalars[k]) {
                while k < n && isPythonWhitespace(scalars[k]) { k += 1 }
                j = k
            }
        }
        // (outline|draft|plan|version)
        let nouns = ["outline", "version", "draft", "plan"]
        var nounMatched = false
        for noun in nouns {
            var l = j
            if matchWordCI(scalars, at: &l, noun) {
                // \b after noun.
                if asciiWordBoundary(at: l, in: scalars) {
                    results.append(MatchResult(start: i, end: l, groups: []))
                    i = l; nounMatched = true; break
                }
            }
        }
        if !nounMatched { i += 1 }
    }
    return results
}

// MARK: - INITIAL_DRAFT_MARKER_RE  (re.IGNORECASE)
// Pattern: \b(?:first|initial|original)\s+(?:chapter\s+)?(?:outline|draft|plan|version)\b

/// finditer for INITIAL_DRAFT_MARKER_RE.
public func initialDraftMarkerREFinditer(_ scalars: [Unicode.Scalar]) -> [MatchResult] {
    var results: [MatchResult] = []
    let n = scalars.count
    var i = 0
    while i < n {
        guard asciiWordBoundary(at: i, in: scalars) else { i += 1; continue }
        var j = i
        let verbs = ["initial", "original", "first"]
        var verbMatched = false
        for v in verbs {
            j = i
            if matchWordCI(scalars, at: &j, v) { verbMatched = true; break }
        }
        guard verbMatched else { i += 1; continue }
        guard j < n && isPythonWhitespace(scalars[j]) else { i += 1; continue }
        while j < n && isPythonWhitespace(scalars[j]) { j += 1 }
        // Optional "chapter\s+"
        var k = j
        if matchWordCI(scalars, at: &k, "chapter") {
            if k < n && isPythonWhitespace(scalars[k]) {
                while k < n && isPythonWhitespace(scalars[k]) { k += 1 }
                j = k
            }
        }
        let nouns = ["outline", "version", "draft", "plan"]
        var nounMatched = false
        for noun in nouns {
            var l = j
            if matchWordCI(scalars, at: &l, noun), asciiWordBoundary(at: l, in: scalars) {
                results.append(MatchResult(start: i, end: l, groups: []))
                i = l; nounMatched = true; break
            }
        }
        if !nounMatched { i += 1 }
    }
    return results
}

// MARK: - OPERATIVE_RE  (re.IGNORECASE)
// Pattern: ^\s*(?:please\s+)?(?:amend|analy[sz]e|answer|check|compare|convert|
//           describe|determine|edit|explain|extract|find|identify|list|review|
//           revise|show|summarize|tell|update|verify|write)\b
// Anchored at ^.  Returns 0 or 1 match.

/// finditer for OPERATIVE_RE.
public func operativeREFinditer(_ scalars: [Unicode.Scalar]) -> [MatchResult] {
    let n = scalars.count
    var i = 0
    while i < n && isPythonWhitespace(scalars[i]) { i += 1 }
    // Optional "please\s+"
    var j = i
    if matchWordCI(scalars, at: &j, "please") {
        // Must be followed by whitespace.
        if j < n && isPythonWhitespace(scalars[j]) {
            while j < n && isPythonWhitespace(scalars[j]) { j += 1 }
            i = j
        }
        // If not followed by whitespace, don't consume "please".
    }
    // The operative verb list.
    // "analyze"/"analyse" — `analy[sz]e` covers both.
    let verbs = ["summarize", "determine", "identify", "describe", "analyze", "analyse",
                 "compare", "convert", "explain", "extract", "update", "review",
                 "verify", "revise", "answer", "check", "amend", "write", "find",
                 "list", "edit", "show", "tell"]
    for verb in verbs {
        var k = i
        if matchWordCI(scalars, at: &k, verb) && asciiWordBoundary(at: k, in: scalars) {
            return [MatchResult(start: 0, end: k, groups: [])]
        }
    }
    return []
}

// MARK: - TURN_FILLER_RE  (re.IGNORECASE)
// Pattern: ^\s*(?:acknowledged|noted|received|ok(?:ay)?|sure|thanks|thank you|
//           got it|understood|sounds good|great|perfect|exactly|absolutely|
//           you(?:'re| are) welcome)[.!\s]*$

/// finditer for TURN_FILLER_RE.
public func turnFillerREFinditer(_ scalars: [Unicode.Scalar]) -> [MatchResult] {
    let n = scalars.count
    var i = 0
    while i < n && isPythonWhitespace(scalars[i]) { i += 1 }
    // Try each alternative in length-descending order.
    let phrases = ["acknowledged", "sounds good", "you're welcome", "you are welcome",
                   "understood", "thank you", "received", "perfectly",
                   "perfect", "exactly", "absolutely",
                   "thanks", "got it", "great", "noted", "okay", "sure", "ok"]
    var matched = false
    for ph in phrases {
        var j = i
        if matchWordCI(scalars, at: &j, ph) {
            i = j; matched = true; break
        }
    }
    guard matched else { return [] }
    // [.!\s]*
    while i < n {
        let v = scalars[i].value
        if isPythonWhitespace(scalars[i]) || v == 0x2E || v == 0x21 { i += 1 } else { break }
    }
    guard i == n else { return [] }
    return [MatchResult(start: 0, end: n, groups: [])]
}

// MARK: - ASSISTANT_BOILERPLATE_RE  (re.IGNORECASE | re.DOTALL)
// Three alternatives, all anchored at ^ and $, with DOTALL (. matches \n).
// Alt 1: ^\s*(?:certainly|sure|of course)[.!,:\s]*(?:i(?:'d| will) be happy to)?\s*$
// Alt 2: ^\s*i hope this helps[.!?\s]*$
// Alt 3: ^\s*let me know if you (?:have|need)(?: any)? (?:questions|anything(?: else)?)[.!?\s]*$
//
// finditer returns 0 or 1 match (whole-string match if any alt matches).

/// finditer for ASSISTANT_BOILERPLATE_RE.
public func assistantBoilerplateREFinditer(_ scalars: [Unicode.Scalar]) -> [MatchResult] {
    let n = scalars.count

    func consumeWhitespace(_ i: inout Int) {
        while i < n && isPythonWhitespace(scalars[i]) { i += 1 }
    }
    // DOTALL: all chars match . (but our scanner doesn't use . directly)

    // Alt 1.
    do {
        var i = 0
        consumeWhitespace(&i)
        var j = i
        let openers = ["of course", "certainly", "sure"]
        var opened = false
        for op in openers {
            j = i
            if matchWordCI(scalars, at: &j, op) { opened = true; break }
        }
        if opened {
            // [.!,:\s]*
            while j < n {
                let v = scalars[j].value
                if isPythonWhitespace(scalars[j]) || v == 0x2E || v == 0x21
                   || v == 0x2C || v == 0x3A { j += 1 } else { break }
            }
            // Optional: i('d| will) be happy to
            var k = j
            if matchWordCI(scalars, at: &k, "i") {
                var l = k
                let contrs = [" will", "'d"]
                var contrMatched = false
                for c in contrs {
                    l = k
                    if matchWordCI(scalars, at: &l, c) { contrMatched = true; break }
                }
                if contrMatched && matchWordCI(scalars, at: &l, " be happy to") {
                    j = l
                }
            }
            // \s*$
            consumeWhitespace(&j)
            if j == n {
                return [MatchResult(start: 0, end: n, groups: [])]
            }
        }
    }
    // Alt 2.
    do {
        var i = 0
        consumeWhitespace(&i)
        if matchWordCI(scalars, at: &i, "i hope this helps") {
            // [.!?\s]*
            while i < n {
                let v = scalars[i].value
                if isPythonWhitespace(scalars[i]) || v == 0x2E || v == 0x21 || v == 0x3F {
                    i += 1
                } else { break }
            }
            if i == n { return [MatchResult(start: 0, end: n, groups: [])] }
        }
    }
    // Alt 3.
    do {
        var i = 0
        consumeWhitespace(&i)
        if matchWordCI(scalars, at: &i, "let me know if you ") {
            // (have|need)
            if matchWordCI(scalars, at: &i, "have") || matchWordCI(scalars, at: &i, "need") {
                // (?: any)?
                var j = i
                if matchWordCI(scalars, at: &j, " any") { i = j }
                // space
                guard i < n && scalars[i].value == 0x20 else { return [] }
                i += 1
                // (questions|anything(?: else)?)
                let opts = ["questions", "anything else", "anything"]
                var optMatched = false
                for opt in opts {
                    var k = i
                    if matchWordCI(scalars, at: &k, opt) { i = k; optMatched = true; break }
                }
                guard optMatched else { return [] }
                // [.!?\s]*
                while i < n {
                    let v = scalars[i].value
                    if isPythonWhitespace(scalars[i]) || v == 0x2E || v == 0x21 || v == 0x3F {
                        i += 1
                    } else { break }
                }
                if i == n { return [MatchResult(start: 0, end: n, groups: [])] }
            }
        }
    }
    return []
}

// MARK: - EMBEDDED_USER_FACT_RE  (re.IGNORECASE)
// Pattern: (?:^|\n).*?(?P<fact>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}[^\n]*?\s[—-]\s*user:\s*[^\n]+)
//
// No DOTALL: .* does not match \n.  The .*? before the fact group is lazy.
// Each line starting from position 0 or after a \n is a candidate.
// Group 0 ("fact") = the timestamp+user portion.
// The full match includes the \n (or starts at 0) and the text before fact.
//
// Algorithm: for each line start (position 0 or position after \n), scan the
// line for the first occurrence of a timestamp, then look for \s[—-]\s*user:
// after the timestamp on the same line.

/// finditer for EMBEDDED_USER_FACT_RE.
public func embeddedUserFactREFinditer(_ scalars: [Unicode.Scalar]) -> [MatchResult] {
    var results: [MatchResult] = []
    let n = scalars.count

    // Helper: find end of line (exclusive; position of next \n or end of string).
    func lineEnd(_ from: Int) -> Int {
        var k = from
        while k < n && scalars[k].value != 0x0A { k += 1 }
        return k
    }

    // Collect line-start positions including position 0.
    // matchStart: index of the anchor char (\n) or 0 for the first line.
    // lineStart: index of the first char of the line content.
    var lineStarts: [(matchStart: Int, lineStart: Int)] = [(0, 0)]
    for idx in 0 ..< n {
        if scalars[idx].value == 0x0A && idx + 1 <= n {
            lineStarts.append((matchStart: idx, lineStart: idx + 1))
        }
    }

    for (ms, ls) in lineStarts {
        let le = lineEnd(ls)
        guard le > ls else { continue }  // empty line after \n
        let line = Array(scalars[ls ..< le])
        let lineN = line.count

        // Scan the line for a timestamp: \d{4}-\d{2}-\d{2}T\d{2}:\d{2}
        var tsStart = 0
        while tsStart < lineN {
            // Try to match timestamp at tsStart.
            guard let tsEnd = matchTimestampPrefix(line, at: tsStart) else {
                tsStart += 1; continue
            }
            // After timestamp: [^\n]*?\s[—-]\s*user:\s*[^\n]+
            // Lazy scan for \s[—-] on the same line.
            var k = tsEnd
            var factEnd: Int? = nil
            while k < lineN {
                // Check for \s followed by [—-] (em-dash U+2014 or hyphen U+002D).
                if isPythonWhitespace(line[k]) && k + 1 < lineN {
                    let nextV = line[k + 1].value
                    if nextV == 0x2014 || nextV == 0x2D {
                        // Found potential separator. Check \s*user:\s*[^\n]+.
                        var m = k + 2
                        while m < lineN && isPythonWhitespace(line[m]) { m += 1 }
                        // "user:" case-insensitively.
                        if matchWordCI(line, at: &m, "user:") {
                            while m < lineN && isPythonWhitespace(line[m]) { m += 1 }
                            // [^\n]+ — must have at least one non-newline char.
                            if m < lineN {
                                // The fact continues to end of line.
                                factEnd = lineN
                                break
                            }
                        }
                    }
                }
                k += 1
            }
            guard let fe = factEnd else { tsStart += 1; continue }
            // Fact group spans tsStart .. fe (in line-relative coords).
            let factAbsStart = ls + tsStart
            let factAbsEnd = ls + fe
            let factText = Array(scalars[factAbsStart ..< factAbsEnd]).asString()
            // Full match spans ms .. factAbsEnd.
            results.append(MatchResult(
                start: ms,
                end: factAbsEnd,
                groups: [factText]
            ))
            // Advance to next line (don't re-match on same line after finding a fact).
            break
        }
    }
    return results
}

/// Attempts to match `\d{4}-\d{2}-\d{2}T\d{2}:\d{2}` at position `i` in `line`.
/// Returns end position or nil.
private func matchTimestampPrefix(_ line: [Unicode.Scalar], at i: Int) -> Int? {
    let n = line.count
    // \d{4}
    guard i + 13 <= n else { return nil }
    for k in 0 ..< 4 { guard isASCIIDigit(line[i + k].value) else { return nil } }
    guard line[i + 4].value == 0x2D else { return nil }
    guard isASCIIDigit(line[i + 5].value) && isASCIIDigit(line[i + 6].value) else { return nil }
    guard line[i + 7].value == 0x2D else { return nil }
    guard isASCIIDigit(line[i + 8].value) && isASCIIDigit(line[i + 9].value) else { return nil }
    // T
    guard line[i + 10].value == 0x54 /* T */ else { return nil }
    guard isASCIIDigit(line[i + 11].value) && isASCIIDigit(line[i + 12].value) else { return nil }
    guard i + 14 <= n && line[i + 13].value == 0x3A else { return nil }
    guard i + 16 <= n && isASCIIDigit(line[i + 14].value) && isASCIIDigit(line[i + 15].value)
    else { return nil }
    return i + 16
}

// MARK: - FENCE_OPEN_RE
// Pattern: ^\s*(`{3,}|~{3,})
// Anchored at ^.  Returns 0 or 1 match.

/// finditer for FENCE_OPEN_RE.
public func fenceOpenREFinditer(_ scalars: [Unicode.Scalar]) -> [MatchResult] {
    let n = scalars.count
    var i = 0
    while i < n && isPythonWhitespace(scalars[i]) { i += 1 }
    guard i < n else { return [] }
    let v = scalars[i].value
    guard v == 0x60 /* ` */ || v == 0x7E /* ~ */ else { return [] }
    let start = i
    let fence = v
    while i < n && scalars[i].value == fence { i += 1 }
    guard i - start >= 3 else { return [] }
    let groupText = scalars[start ..< i].asString()
    return [MatchResult(start: 0, end: i, groups: [groupText])]
}

// MARK: - MARKDOWN_HEADING_RE
// Pattern: ^(?P<marks>#{1,6})\s+\S
// Anchored at ^.  Group 0 ("marks") = the # signs.  Returns 0 or 1 match.

/// finditer for MARKDOWN_HEADING_RE.
public func markdownHeadingREFinditer(_ scalars: [Unicode.Scalar]) -> [MatchResult] {
    let n = scalars.count
    guard n > 0 && scalars[0].value == 0x23 /* # */ else { return [] }
    var i = 0
    while i < n && scalars[i].value == 0x23 && i < 6 { i += 1 }
    let markCount = i
    guard markCount >= 1 else { return [] }
    // \s+
    guard i < n && isPythonWhitespace(scalars[i]) else { return [] }
    while i < n && isPythonWhitespace(scalars[i]) { i += 1 }
    // \S — one non-whitespace char must follow.
    guard i < n && !isPythonWhitespace(scalars[i]) else { return [] }
    let marksText = String(String.UnicodeScalarView(scalars[0 ..< markCount]))
    // End of match is at i+1 (includes the \S char).
    return [MatchResult(start: 0, end: i + 1, groups: [marksText])]
}

// MARK: - BOLD_HEADING_RE
// Pattern: ^\s*\*\*[^*\n]{1,120}\*\*\s*:?[ \t]*$
// Anchored at ^ and $.  Returns 0 or 1 match.

/// finditer for BOLD_HEADING_RE.
public func boldHeadingREFinditer(_ scalars: [Unicode.Scalar]) -> [MatchResult] {
    let n = scalars.count
    var i = 0
    while i < n && isPythonWhitespace(scalars[i]) { i += 1 }
    // \*\*
    guard i + 1 < n && scalars[i].value == 0x2A && scalars[i + 1].value == 0x2A
    else { return [] }
    i += 2
    let contentStart = i
    // [^*\n]{1,120}
    var count = 0
    while i < n && scalars[i].value != 0x2A && scalars[i].value != 0x0A && count < 120 {
        i += 1; count += 1
    }
    guard count >= 1 else { return [] }
    // \*\*
    guard i + 1 < n && scalars[i].value == 0x2A && scalars[i + 1].value == 0x2A
          && contentStart < i  // at least 1 content char
    else { return [] }
    i += 2
    // \s*  (but no \n — $ without MULTILINE means end of string or before \n)
    while i < n && (scalars[i].value == 0x20 || scalars[i].value == 0x09) { i += 1 }
    // :?
    if i < n && scalars[i].value == 0x3A { i += 1 }
    // [ \t]*
    while i < n && (scalars[i].value == 0x20 || scalars[i].value == 0x09) { i += 1 }
    // $ — end of string (no MULTILINE).
    guard i == n else { return [] }
    return [MatchResult(start: 0, end: n, groups: [])]
}

// MARK: - FIELD_LINE_RE
// Pattern: ^\s*[A-Za-z][A-Za-z0-9 _./()-]{0,80}:\s*\S
// Anchored at ^.  Returns 0 or 1 match.

/// finditer for FIELD_LINE_RE.
public func fieldLineREFinditer(_ scalars: [Unicode.Scalar]) -> [MatchResult] {
    let n = scalars.count
    var i = 0
    while i < n && isPythonWhitespace(scalars[i]) { i += 1 }
    // [A-Za-z]
    guard i < n && isASCIIAlpha(scalars[i].value) else { return [] }
    i += 1
    // [A-Za-z0-9 _./()-]{0,80}
    var count = 0
    while i < n && count < 80 {
        let v = scalars[i].value
        if isASCIIAlnum(v) || v == 0x20 || v == 0x5F || v == 0x2E || v == 0x2F
           || v == 0x28 || v == 0x29 || v == 0x2D {
            i += 1; count += 1
        } else { break }
    }
    // :
    guard i < n && scalars[i].value == 0x3A else { return [] }
    i += 1
    // \s*
    while i < n && isPythonWhitespace(scalars[i]) { i += 1 }
    // \S — at least one non-whitespace.
    guard i < n && !isPythonWhitespace(scalars[i]) else { return [] }
    return [MatchResult(start: 0, end: i + 1, groups: [])]
}

// MARK: - TABLE_SEPARATOR_RE
// Pattern: ^\s*\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)+\|?\s*$
// Anchored at ^ and $.  Returns 0 or 1 match.

/// Attempts to parse one cell separator segment `:?-{3,}:?` at `i`.
/// Returns end position or nil.
private func matchTableCell(_ s: [Unicode.Scalar], at i: inout Int) {
    let n = s.count
    // \s*
    while i < n && isPythonWhitespace(s[i]) { i += 1 }
    // :?
    if i < n && s[i].value == 0x3A { i += 1 }
    // -{3,}
    let dashStart = i
    while i < n && s[i].value == 0x2D { i += 1 }
    if i - dashStart < 3 { return }  // need at least 3
    // :?
    if i < n && s[i].value == 0x3A { i += 1 }
    // \s*
    while i < n && isPythonWhitespace(s[i]) { i += 1 }
}

/// finditer for TABLE_SEPARATOR_RE.
public func tableSeparatorREFinditer(_ scalars: [Unicode.Scalar]) -> [MatchResult] {
    let n = scalars.count
    var i = 0
    // \s*
    while i < n && isPythonWhitespace(scalars[i]) { i += 1 }
    // \|?
    if i < n && scalars[i].value == 0x7C { i += 1 }
    // First cell: \s*:?-{3,}:?\s*
    let beforeFirstCell = i
    matchTableCell(scalars, at: &i)
    guard i > beforeFirstCell else { return [] }
    // (?:\|\s*:?-{3,}:?\s*)+ — at least ONE pipe+cell.
    guard i < n && scalars[i].value == 0x7C else { return [] }
    var cellCount = 0
    while i < n && scalars[i].value == 0x7C {
        i += 1  // consume |
        let beforeCell = i
        matchTableCell(scalars, at: &i)
        guard i > beforeCell else { break }
        cellCount += 1
    }
    guard cellCount >= 1 else { return [] }
    // Trailing \|?
    if i < n && scalars[i].value == 0x7C { i += 1 }
    // \s*
    while i < n && isPythonWhitespace(scalars[i]) { i += 1 }
    // $
    guard i == n else { return [] }
    return [MatchResult(start: 0, end: n, groups: [])]
}

// MARK: - DIAGRAM_RE
// Pattern: [─-╿]|(?:--?>|==>|<--?)
// No anchors, no groups.  Finds box-drawing chars and ASCII arrow sequences.

/// finditer for DIAGRAM_RE.
public func diagramREFinditer(_ scalars: [Unicode.Scalar]) -> [MatchResult] {
    var results: [MatchResult] = []
    let n = scalars.count
    var i = 0
    while i < n {
        let v = scalars[i].value
        // Box-drawing characters U+2500–U+257F.
        if v >= 0x2500 && v <= 0x257F {
            results.append(MatchResult(start: i, end: i + 1, groups: []))
            i += 1; continue
        }
        // --> or ->
        if v == 0x2D {
            if i + 2 < n && scalars[i + 1].value == 0x2D && scalars[i + 2].value == 0x3E {
                results.append(MatchResult(start: i, end: i + 3, groups: []))
                i += 3; continue
            }
            if i + 1 < n && scalars[i + 1].value == 0x3E {
                results.append(MatchResult(start: i, end: i + 2, groups: []))
                i += 2; continue
            }
        }
        // ==>
        if v == 0x3D && i + 2 < n && scalars[i + 1].value == 0x3D && scalars[i + 2].value == 0x3E {
            results.append(MatchResult(start: i, end: i + 3, groups: []))
            i += 3; continue
        }
        // <-- or <-
        if v == 0x3C {
            if i + 2 < n && scalars[i + 1].value == 0x2D && scalars[i + 2].value == 0x2D {
                results.append(MatchResult(start: i, end: i + 3, groups: []))
                i += 3; continue
            }
            if i + 1 < n && scalars[i + 1].value == 0x2D {
                results.append(MatchResult(start: i, end: i + 2, groups: []))
                i += 2; continue
            }
        }
        i += 1
    }
    return results
}

// MARK: - POLARITY_ONLY_RE  (re.IGNORECASE)
// Pattern: ^\s*(?:yes|no)\b[.!?\s]*$
// Anchored at ^ and $.  Returns 0 or 1 match.

/// finditer for POLARITY_ONLY_RE.
public func polarityOnlyREFinditer(_ scalars: [Unicode.Scalar]) -> [MatchResult] {
    let n = scalars.count
    var i = 0
    while i < n && isPythonWhitespace(scalars[i]) { i += 1 }
    guard matchWordCI(scalars, at: &i, "yes") || matchWordCI(scalars, at: &i, "no")
    else { return [] }
    guard asciiWordBoundary(at: i, in: scalars) else { return [] }
    // [.!?\s]*
    while i < n {
        let v = scalars[i].value
        if isPythonWhitespace(scalars[i]) || v == 0x2E || v == 0x21 || v == 0x3F {
            i += 1
        } else { break }
    }
    guard i == n else { return [] }
    return [MatchResult(start: 0, end: n, groups: [])]
}

// MARK: - TRANSFORM_FOLLOWUP_RE  (re.IGNORECASE)
// Two alternative patterns (joined with |), both searching the text:
// Alt A: \b(adapt|convert|make|port|rewrite|translate|turn)\b[^\n]{0,120}\b(answer|code|example|function|it|that|this)\b
// Alt B: \b(answer|code|example|function|it|that|this)\b[^\n]{0,120}\b(adapt|convert|make|port|rewrite|translate|turn)\b
//
// [^\n]{0,120} means up to 120 non-newline characters.
// finditer returns non-overlapping matches.

private let transformVerbs = ["translate", "rewrite", "convert", "adapt", "port", "make", "turn"]
private let transformNouns = ["function", "example", "answer", "code", "that", "this", "it"]

/// Returns `true` if the word at `scalars[i...]` (at word boundary) matches
/// any word in `words` (case-insensitive) and ends at a word boundary.
/// Advances `i` past the match.
private func matchAnyWord(
    _ scalars: [Unicode.Scalar], at i: inout Int, _ words: [String]
) -> Bool {
    for w in words {
        var k = i
        if matchWordCI(scalars, at: &k, w) && asciiWordBoundary(at: k, in: scalars) {
            i = k; return true
        }
    }
    return false
}

/// finditer for TRANSFORM_FOLLOWUP_RE.
public func transformFollowupREFinditer(_ scalars: [Unicode.Scalar]) -> [MatchResult] {
    // TRANSFORM_FOLLOWUP_RE:
    //   \b(?:verb)\b[^\n]{0,120}\b(?:noun)\b
    //   | \b(?:noun)\b[^\n]{0,120}\b(?:verb)\b
    //
    // Python's regex engine is GREEDY: [^\n]{0,120} expands as far as possible,
    // then backtracks to find the LAST valid second-keyword endpoint within 120
    // non-newline chars.  A forward scan that stops at the FIRST keyword produces
    // shorter matches and leaves overlapping regions that generate extra matches.
    //
    // Correct strategy: after consuming the leading keyword, collect ALL positions
    // within [0, 120] non-newline chars where the trailing keyword ends, then pick
    // the RIGHTMOST one (greedy semantics).  Advance i to that end position.

    var results: [MatchResult] = []
    let n = scalars.count
    var i = 0

    /// Returns the greedy (rightmost) end position of a trailing keyword match
    /// within 120 non-newline chars starting at `from`, or nil if none found.
    func greedyTrailing(
        _ scalars: [Unicode.Scalar], from: Int, words: [String]
    ) -> Int? {
        let n = scalars.count
        var charsConsumed = 0
        var k = from
        var best: Int? = nil
        while k <= n && charsConsumed <= 120 {
            // A newline terminates [^\n]{0,120}.
            if k < n && scalars[k].value == 0x0A { break }
            if asciiWordBoundary(at: k, in: scalars) {
                var l = k
                if matchAnyWord(scalars, at: &l, words) {
                    best = l  // keep updating — greedy finds the last valid endpoint
                }
            }
            if k < n { charsConsumed += 1 }
            k += 1
        }
        return best
    }

    while i < n {
        guard asciiWordBoundary(at: i, in: scalars) else { i += 1; continue }

        // Try Alt A: verb [^\n]{0,120} noun.
        var j = i
        if matchAnyWord(scalars, at: &j, transformVerbs) {
            if let end = greedyTrailing(scalars, from: j, words: transformNouns) {
                results.append(MatchResult(start: i, end: end, groups: []))
                i = end
                continue
            }
        }

        // Try Alt B: noun [^\n]{0,120} verb.
        j = i
        if matchAnyWord(scalars, at: &j, transformNouns) {
            if let end = greedyTrailing(scalars, from: j, words: transformVerbs) {
                results.append(MatchResult(start: i, end: end, groups: []))
                i = end
                continue
            }
        }

        i += 1
    }
    return results
}

// MARK: - QUANTITY_VALUE_RE
// Pattern: ^[€£$]?\d+(?:[.,]\d+)?(?:\s+[A-Za-z%][A-Za-z0-9%._/-]*){0,3}$
// Anchored at ^ and $.  Returns 0 or 1 match.

/// finditer for QUANTITY_VALUE_RE.
public func quantityValueREFinditer(_ scalars: [Unicode.Scalar]) -> [MatchResult] {
    let n = scalars.count
    var i = 0
    // [€£$]?
    if i < n {
        let v = scalars[i].value
        if v == 0x20AC /* € */ || v == 0xA3 /* £ */ || v == 0x24 /* $ */ { i += 1 }
    }
    // \d+
    guard i < n && isASCIIDigit(scalars[i].value) else { return [] }
    while i < n && isASCIIDigit(scalars[i].value) { i += 1 }
    // (?:[.,]\d+)?
    if i < n && (scalars[i].value == 0x2E || scalars[i].value == 0x2C)
       && i + 1 < n && isASCIIDigit(scalars[i + 1].value) {
        i += 1
        while i < n && isASCIIDigit(scalars[i].value) { i += 1 }
    }
    // (?:\s+[A-Za-z%][A-Za-z0-9%._/-]*){0,3}
    for _ in 0 ..< 3 {
        guard i < n && isPythonWhitespace(scalars[i]) else { break }
        var j = i
        while j < n && isPythonWhitespace(scalars[j]) { j += 1 }
        guard j < n else { break }
        let v = scalars[j].value
        guard isASCIIAlpha(v) || v == 0x25 /* % */ else { break }
        j += 1
        while j < n {
            let sv = scalars[j].value
            if isASCIIAlnum(sv) || sv == 0x25 || sv == 0x2E || sv == 0x5F
               || sv == 0x2F || sv == 0x2D { j += 1 } else { break }
        }
        i = j
    }
    // $
    guard i == n else { return [] }
    return [MatchResult(start: 0, end: n, groups: [])]
}

// MARK: - Dispatch table

/// Calls the appropriate finditer function for the named pattern.
///
/// - Parameter name: One of the 26 pattern constant names from
///   distill_plus_converter.py (e.g. "WORD_RE", "DATE_RE").
/// - Parameter scalars: The text to scan.
/// - Returns: All matches in document order.
public func finditer(pattern name: String, in scalars: [Unicode.Scalar]) -> [MatchResult] {
    switch name {
    case "TRAILER_RE":               return trailerREFinditer(scalars)
    case "PIPE_SPLIT_RE":            return pipeSplitREFinditer(scalars)
    case "INLINE_NUMBERED_RE":       return inlineNumberedREFinditer(scalars)
    case "LIST_MARKER_RE":           return listMarkerREFinditer(scalars)
    case "WORD_RE":                  return wordREFinditer(scalars)
    case "NUMBER_RE":                return numberREFinditer(scalars)
    case "DATE_RE":                  return dateREFinditer(scalars)
    case "CAPITALIZED_RE":           return capitalizedREFinditer(scalars)
    case "GREETING_PREFIX_RE":       return greetingPrefixREFinditer(scalars)
    case "GREETING_ONLY_RE":         return greetingOnlyREFinditer(scalars)
    case "DIALOGUE_FILLER_ONLY_RE":  return dialogueFillerOnlyREFinditer(scalars)
    case "REVISION_MARKER_RE":       return revisionMarkerREFinditer(scalars)
    case "INITIAL_DRAFT_MARKER_RE":  return initialDraftMarkerREFinditer(scalars)
    case "OPERATIVE_RE":             return operativeREFinditer(scalars)
    case "TURN_FILLER_RE":           return turnFillerREFinditer(scalars)
    case "ASSISTANT_BOILERPLATE_RE": return assistantBoilerplateREFinditer(scalars)
    case "EMBEDDED_USER_FACT_RE":    return embeddedUserFactREFinditer(scalars)
    case "FENCE_OPEN_RE":            return fenceOpenREFinditer(scalars)
    case "MARKDOWN_HEADING_RE":      return markdownHeadingREFinditer(scalars)
    case "BOLD_HEADING_RE":          return boldHeadingREFinditer(scalars)
    case "FIELD_LINE_RE":            return fieldLineREFinditer(scalars)
    case "TABLE_SEPARATOR_RE":       return tableSeparatorREFinditer(scalars)
    case "DIAGRAM_RE":               return diagramREFinditer(scalars)
    case "POLARITY_ONLY_RE":         return polarityOnlyREFinditer(scalars)
    case "TRANSFORM_FOLLOWUP_RE":    return transformFollowupREFinditer(scalars)
    case "QUANTITY_VALUE_RE":        return quantityValueREFinditer(scalars)
    default:
        preconditionFailure("Unknown pattern: \(name)")
    }
}
