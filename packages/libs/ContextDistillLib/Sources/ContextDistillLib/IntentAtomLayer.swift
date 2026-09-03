// IntentAtomLayer.swift
// Port of the atom-building layer from distill_plus_converter.py.
//
// Public entry points:
//   intentAtoms(_:)       — mirrors _intent_atoms
//   speakerTurns(_:)      — mirrors _speaker_turns
//   structuredAtoms(_:)   — mirrors _structured_atoms
//   reindexAtoms(_:)      — mirrors _reindex_atoms
//   normalizedTerms(_:)   — mirrors _normalized_terms
//
// Design rules (from the decision record):
//   - NO regex engine. All pattern matching is hand-written character scanners.
//   - Index unit: unicodeScalars (code points). Python str indices are code
//     points; Swift unicodeScalars is the exact same unit.
//   - Python integer semantics: all division is truncating.
//   - Stable sort: Swift sorted() is stable, matching Python.
//   - No Date(), no randomness. Pure functions.

import Foundation

// MARK: - Local ASCII helpers
// Mirrors the private helpers in Scanners.swift; redefined here to avoid
// reaching through that file's private access level.
@inline(__always) private func atlIsUpper(_ v: UInt32) -> Bool { v >= 0x41 && v <= 0x5A }
@inline(__always) private func atlIsLower(_ v: UInt32) -> Bool { v >= 0x61 && v <= 0x7A }
@inline(__always) private func atlIsAlpha(_ v: UInt32) -> Bool { atlIsUpper(v) || atlIsLower(v) }
@inline(__always) private func atlIsDigit(_ v: UInt32) -> Bool { v >= 0x30 && v <= 0x39 }
@inline(__always) private func atlIsAlnum(_ v: UInt32) -> Bool { atlIsAlpha(v) || atlIsDigit(v) }

/// Converts a `[Unicode.Scalar]` slice to a `String`.
private func scalarsToString(_ scalars: [Unicode.Scalar]) -> String {
    var s = ""
    s.unicodeScalars.append(contentsOf: scalars)
    return s
}

/// Converts a range of `[Unicode.Scalar]` to a `String`.
private func scalarsToString(_ scalars: [Unicode.Scalar], _ range: Range<Int>) -> String {
    var s = ""
    s.unicodeScalars.append(contentsOf: scalars[range])
    return s
}

// MARK: - KNOWN_SPEAKERS
// Mirrors KNOWN_SPEAKERS in record_shape_classifier.py.
private let knownSpeakersAtom: Set<String> = [
    "user", "assistant", "human", "system", "customer", "agent",
    "interviewer", "interviewee", "speaker", "participant",
]

// MARK: - KNOWN_USER_SPEAKERS / KNOWN_ANSWER_SPEAKERS
// Mirrors KNOWN_USER_SPEAKERS and KNOWN_ANSWER_SPEAKERS in distill_plus_converter.py.
private let knownUserSpeakers: Set<String> = ["user", "human", "customer", "interviewer"]
private let knownAnswerSpeakers: Set<String> = ["assistant", "agent", "system", "interviewee"]

// Metadata labels that must never be treated as named conversation peers.
// Mirrors PEER_FIELD_LABELS in the v23 Python authority.
private let peerFieldLabels: Set<String> = [
    "address", "country", "date", "email", "entity", "id", "location",
    "name", "notes", "phone", "place", "quantity", "status", "subject",
    "title", "type",
]

// MARK: - ABBREVIATIONS
// Mirrors ABBREVIATIONS in distill_plus_converter.py.
private let abbreviations: Set<String> = [
    "dr", "e.g", "i.e", "jr", "mr", "mrs", "ms", "prof", "sr", "u.s",
    "u.k", "vs",
]

// MARK: - SCORING_STOPWORDS
// Mirrors SCORING_STOPWORDS in distill_plus_converter.py.
private let scoringStopwords: Set<String> = {
    let stop: Set<String> = [
        "really", "very", "quite", "actually", "basically",
        "literally", "honestly", "frankly", "anyway", "please",
    ]
    let extra: Set<String> = [
        "a", "an", "the", "and", "as", "at", "be", "been", "being", "by", "for", "from", "in",
        "of", "on", "or", "that", "this", "to", "was", "were", "with", "you",
        "your", "we", "our", "they", "their", "it", "its", "i", "my", "me",
    ]
    return stop.union(extra)
}()

// MARK: - QUERY_STOPWORDS
// Mirrors QUERY_STOPWORDS in distill_plus_converter.py.
private let queryStopwords: Set<String> = {
    let extra: Set<String> = [
        "answer", "analyze", "check", "compare", "convert", "describe",
        "document", "explain", "extract", "find", "following", "identify",
        "list", "question", "review", "show", "summarize", "tell", "text",
        "verify", "write",
    ]
    return scoringStopwords.union(extra)
}()

// MARK: - ACTION_WORDS and ACTION_STEMS
// Mirrors ACTION_WORDS and ACTION_STEMS in distill_plus_converter.py.
private let actionWords: [String] = [
    "agreed", "approved", "assigned", "build", "built", "cancel", "changed",
    "choose", "decided", "deliver", "due", "failed", "fixed", "launch",
    "must", "need", "planned", "prefer", "preferred", "prefers",
    "preference", "favorite", "routine", "regularly", "usually", "required",
    "ship", "shipped", "should", "started", "stop", "will", "won't",
]

// Computed at module-load time.
// Mirrors: ACTION_STEMS = frozenset(term for word in ACTION_WORDS
//                                   for term in _normalized_terms(word))
private let actionStems: Set<String> = {
    var stems = Set<String>()
    for word in actionWords {
        for term in normalizedTerms(word) {
            stems.insert(term)
        }
    }
    return stems
}()

// MARK: - IntentAtom

/// An indivisible, exact source span used by the intent-span candidate.
///
/// Mirrors the Python ``IntentAtom`` frozen dataclass in distill_plus_converter.py.
/// All offsets are **code-point** (unicodeScalars) positions in the original source.
public struct IntentAtom: Sendable, Equatable {

    /// Sequential identifier, 0-based.
    public let atomID: Int

    /// Code-point index of the atom's first character (inclusive).
    public let start: Int

    /// Code-point index one past the atom's last character (exclusive).
    public let end: Int

    /// Exact source slice ``source[start..<end]``.
    public let text: String

    /// Structural kind: "sentence-or-entry", "field-entry", "heading",
    /// "list-item", "paragraph", "fenced-code", "indented-code", "table",
    /// "diagram", "substantive-user-turn", "operative-request", "answer-*", etc.
    public let kind: String

    /// Casefolded speaker name; nil for non-dialogue atoms.
    public let speaker: String?

    /// IDs of atoms that must be included whenever this atom is selected.
    public let dependencies: [Int]

    /// True when this atom is unconditionally required in the output.
    public let hardRequired: Bool

    public init(
        atomID: Int,
        start: Int,
        end: Int,
        text: String,
        kind: String,
        speaker: String? = nil,
        dependencies: [Int] = [],
        hardRequired: Bool = false
    ) {
        self.atomID = atomID
        self.start = start
        self.end = end
        self.text = text
        self.kind = kind
        self.speaker = speaker
        self.dependencies = dependencies
        self.hardRequired = hardRequired
    }
}

// MARK: - SpeakerTurn

/// One contiguous speaker turn parsed from a dialogue record.
///
/// Mirrors the Python ``SpeakerTurn`` frozen dataclass.
public struct SpeakerTurn: Sendable, Equatable {

    /// Code-point offset of the first character of this turn's opening line.
    public let start: Int

    /// Code-point offset where this turn ends (exclusive).
    public let end: Int

    /// Code-point offset just past the first-line newline.
    public let firstLineEnd: Int

    /// Code-point offset where the body begins (after ``Speaker:``).
    public let bodyStart: Int

    /// Casefolded speaker name extracted from the turn's opening label.
    public let speaker: String

    public init(start: Int, end: Int, firstLineEnd: Int, bodyStart: Int, speaker: String) {
        self.start = start
        self.end = end
        self.firstLineEnd = firstLineEnd
        self.bodyStart = bodyStart
        self.speaker = speaker
    }
}

// MARK: - physicalLines

/// Returns exact physical-line spans including each line terminator.
///
/// Mirrors Python's ``_physical_lines``.
///
/// - Returns: Triples of `(lineStart, lineEnd, visibleText)` where `lineEnd`
///   includes the `\n` and `visibleText` has trailing `\r\n` stripped.
func physicalLines(
    _ scalars: [Unicode.Scalar],
    start: Int = 0,
    stop: Int? = nil
) -> [(Int, Int, String)] {
    let stopIdx = stop ?? scalars.count
    var result: [(Int, Int, String)] = []
    var cursor = start
    while cursor < stopIdx {
        // Find next \n
        var newline = -1
        var i = cursor
        while i < stopIdx {
            if scalars[i].value == 0x0A { newline = i; break }
            i += 1
        }
        let lineEnd = newline < 0 ? stopIdx : newline + 1
        // Strip trailing \r\n
        var visEnd = lineEnd
        while visEnd > cursor && (scalars[visEnd - 1].value == 0x0A || scalars[visEnd - 1].value == 0x0D) {
            visEnd -= 1
        }
        let visible = scalarsToString(scalars, cursor ..< visEnd)
        result.append((cursor, lineEnd, visible))
        cursor = lineEnd
    }
    return result
}

// MARK: - matchTagLineAtom

/// Matches the content-only TAG_LINE grammar at the start of `line`.
///
/// Pattern (record_shape_classifier.py):
/// ``^\s*([A-Za-z][A-Za-z0-9_ -]{0,23}):\s*(.*)$``
///
/// Returns `(casefolded_speaker, bodyOffset)` where `bodyOffset` is the
/// code-point index within `line` where group(2) starts.
private func matchAnyTagLineAtom(_ line: String) -> (speaker: String, bodyOffset: Int)? {
    let sc = Array(line.unicodeScalars)
    let n = sc.count
    var i = 0
    // ^\s* — skip leading whitespace
    while i < n && isPythonWhitespace(sc[i]) { i += 1 }
    // [A-Za-z]
    guard i < n, atlIsAlpha(sc[i].value) else { return nil }
    let tagStart = i
    i += 1
    // [A-Za-z0-9_ -]{0,23}
    var tagLen = 0
    while i < n && tagLen < 23 {
        let v = sc[i].value
        if atlIsAlnum(v) || v == 0x5F /* _ */ || v == 0x20 /* space */ || v == 0x2D /* - */ {
            i += 1; tagLen += 1
        } else {
            break
        }
    }
    // :
    guard i < n && sc[i].value == 0x3A else { return nil }
    let tagEnd = i
    i += 1
    // \s*
    while i < n && isPythonWhitespace(sc[i]) { i += 1 }
    // group(1) = sc[tagStart..<tagEnd], stripped and casefolded
    let rawTag = scalarsToString(sc, tagStart ..< tagEnd)
    let tag = rawTag.trimmingCharacters(in: .whitespaces).lowercased()
    return (tag, i)
}

/// Matches a TAG_LINE only when its label is a pinned dialogue role.
private func matchTagLineAtom(_ line: String) -> (speaker: String, bodyOffset: Int)? {
    guard let match = matchAnyTagLineAtom(line),
          knownSpeakersAtom.contains(match.speaker) || match.speaker.hasPrefix("speaker ") else {
        return nil
    }
    return match
}

// MARK: - knownSpeakerAtom

/// Returns the casefolded speaker name and code-point body-start offset within
/// `line`, or `nil` when `line` is not a known-speaker label.
///
/// Mirrors Python's ``_known_speaker``.
func knownSpeakerAtom(_ line: String) -> (speaker: String, bodyOffset: Int)? {
    matchTagLineAtom(line)
}

// MARK: - speakerTurns

/// Parses speaker turns from `scalars`, skipping labels inside fenced blocks.
///
/// Mirrors Python's ``_speaker_turns``.
public func speakerTurns(_ scalars: [Unicode.Scalar]) -> [SpeakerTurn] {
    var markers: [(lineStart: Int, lineEnd: Int, bodyStart: Int, speaker: String)] = []
    var fenceChar: UInt32? = nil

    for (lineStart, lineEnd, visible) in physicalLines(scalars) {
        let visScalars = Array(visible.unicodeScalars)
        // FENCE_OPEN_RE: ^\s*(`{3,}|~{3,})
        let fenceMatches = fenceOpenREFinditer(visScalars)
        if !fenceMatches.isEmpty, let token = fenceMatches[0].groups[0] {
            let marker = token.unicodeScalars.first!.value
            if fenceChar == nil {
                fenceChar = marker
            } else if marker == fenceChar {
                fenceChar = nil
            }
            continue
        }
        if fenceChar != nil { continue }

        if let (speaker, bodyLocalOffset) = matchTagLineAtom(visible) {
            let bodyStart = lineStart + bodyLocalOffset
            markers.append((lineStart, lineEnd, bodyStart, speaker))
        }
    }

    var turns: [SpeakerTurn] = []
    for (idx, m) in markers.enumerated() {
        let turnEnd = idx + 1 < markers.count ? markers[idx + 1].lineStart : scalars.count
        turns.append(SpeakerTurn(
            start: m.lineStart,
            end: turnEnd,
            firstLineEnd: m.lineEnd,
            bodyStart: m.bodyStart,
            speaker: m.speaker
        ))
    }
    return turns
}

/// Parses a strict alternating two-person transcript whose speakers use
/// ordinary names rather than pinned chat roles.
///
/// The topology thresholds mirror `_peer_speaker_turns` in the v23 Python
/// authority: exactly two labels, at least six tagged turns, at least 90%
/// tagged-line coverage, and at least 75% switching. Labels used as ordinary
/// metadata fields are excluded. Lines inside fenced blocks are ignored.
private func peerSpeakerTurns(_ scalars: [Unicode.Scalar]) -> [SpeakerTurn] {
    var visibleLineCount = 0
    var markers: [(lineStart: Int, lineEnd: Int, bodyStart: Int, speaker: String)] = []
    var labels: [String] = []
    var fenceChar: UInt32? = nil

    for (lineStart, lineEnd, visible) in physicalLines(scalars) {
        let visibleScalars = Array(visible.unicodeScalars)
        let fenceMatches = fenceOpenREFinditer(visibleScalars)
        if !fenceMatches.isEmpty, let token = fenceMatches[0].groups[0],
           let marker = token.unicodeScalars.first?.value {
            if fenceChar == nil {
                fenceChar = marker
            } else if marker == fenceChar {
                fenceChar = nil
            }
            continue
        }
        if fenceChar != nil || pyStrip(visibleScalars).isEmpty { continue }

        visibleLineCount += 1
        guard let match = matchAnyTagLineAtom(visible) else { continue }
        labels.append(match.speaker)
        markers.append((lineStart, lineEnd, lineStart + match.bodyOffset, match.speaker))
    }

    let distinct = Set(labels)
    let switches = zip(labels, labels.dropFirst()).filter { pair in
        pair.0 != pair.1
    }.count
    guard labels.count >= 6,
          distinct.count == 2,
          distinct.isDisjoint(with: knownSpeakersAtom),
          distinct.isDisjoint(with: peerFieldLabels),
          labels.count * 100 / max(1, visibleLineCount) >= 90,
          switches * 100 / max(1, labels.count - 1) >= 75 else {
        return []
    }

    return markers.enumerated().map { index, marker in
        SpeakerTurn(
            start: marker.lineStart,
            end: index + 1 < markers.count ? markers[index + 1].lineStart : scalars.count,
            firstLineEnd: marker.lineEnd,
            bodyStart: marker.bodyStart,
            speaker: marker.speaker
        )
    }
}

// MARK: - headingLevel

/// Returns the heading level of `visible` (1-6 Markdown #, 7 bold heading,
/// 1 keyword heading), or `nil` when not a heading.
///
/// Mirrors Python's ``_heading_level``.
func headingLevel(_ visible: String) -> Int? {
    let sc = Array(visible.unicodeScalars)
    // MARKDOWN_HEADING_RE: ^(?P<marks>#{1,6})\s+\S
    let md = markdownHeadingREFinditer(sc)
    if !md.isEmpty, let marks = md[0].groups[0] {
        return marks.unicodeScalars.count
    }
    // BOLD_HEADING_RE: ^\s*\*\*[^*\n]{1,120}\*\*\s*:?[ \t]*$
    if !boldHeadingREFinditer(sc).isEmpty { return 7 }
    // HEADING_LEAD keyword match
    if matchHeadingLeadAtom(visible) { return 1 }
    return nil
}

/// Matches HEADING_LEAD keyword pattern (case-insensitive).
///
/// Pattern from record_shape_classifier.py:
/// ``^\s*(?:chapter|section|part|act|scene|title|book summary)\b``
private func matchHeadingLeadAtom(_ line: String) -> Bool {
    let sc = Array(line.unicodeScalars)
    let n = sc.count
    var i = 0
    while i < n && isPythonWhitespace(sc[i]) { i += 1 }
    // Build lowercase remaining
    var remaining: [Unicode.Scalar] = []
    for j in i ..< n {
        remaining.append(sc[j].value >= 0x41 && sc[j].value <= 0x5A
            ? Unicode.Scalar(sc[j].value + 0x20)!
            : sc[j])
    }
    for kw in ["chapter", "section", "part", "act", "scene", "title", "book summary"] {
        let kwSc = Array(kw.unicodeScalars)
        let kwLen = kwSc.count
        guard remaining.count >= kwLen else { continue }
        guard remaining[0 ..< kwLen].elementsEqual(kwSc) else { continue }
        // \b: next character must be non-word or end-of-string
        if kwLen == remaining.count { return true }
        if !isPythonWordChar(remaining[kwLen]) { return true }
    }
    return false
}

// MARK: - isListLine

/// Returns `true` when `visible` starts with a list marker.
///
/// Mirrors Python's ``_is_list_line`` using BULLET_LEAD from record_shape_classifier.py.
/// Pattern: ``^\s*(?:[-*+]\s+|\d+[.)]\s+)``
func isListLine(_ visible: String) -> Bool {
    let sc = Array(visible.unicodeScalars)
    let n = sc.count
    var i = 0
    while i < n && isPythonWhitespace(sc[i]) { i += 1 }
    guard i < n else { return false }
    let v = sc[i].value
    // [-*+]\s+
    if v == 0x2D || v == 0x2A || v == 0x2B {
        i += 1
        return i < n && isPythonWhitespace(sc[i])
    }
    // \d+[.)]\s+
    guard atlIsDigit(v) else { return false }
    while i < n && atlIsDigit(sc[i].value) { i += 1 }
    guard i < n && (sc[i].value == 0x2E || sc[i].value == 0x29) else { return false }
    i += 1
    return i < n && isPythonWhitespace(sc[i])
}

// MARK: - indentWidth

/// Returns the visual indent width of `visible` in spaces (tabs = 4 spaces).
///
/// Mirrors Python's ``_indent_width``.
func indentWidth(_ visible: String) -> Int {
    var width = 0
    for s in visible.unicodeScalars {
        if s.value == 0x09 { width += 4 }
        else if s.value == 0x20 { width += 1 }
        else { break }
    }
    return width
}

// MARK: - appendExactAtom

/// Appends an ``IntentAtom`` to `atoms` and returns it.
///
/// Mirrors Python's ``_append_exact_atom``.
@discardableResult
func appendExactAtom(
    _ atoms: inout [IntentAtom],
    scalars: [Unicode.Scalar],
    start: Int,
    end: Int,
    kind: String,
    speaker: String? = nil,
    dependencies: [Int] = [],
    hardRequired: Bool = false
) -> IntentAtom {
    let text = scalarsToString(scalars, start ..< end)
    let atom = IntentAtom(
        atomID: atoms.count,
        start: start,
        end: end,
        text: text,
        kind: kind,
        speaker: speaker,
        dependencies: dependencies,
        hardRequired: hardRequired
    )
    atoms.append(atom)
    return atom
}

// MARK: - periodIsAbbreviation

/// Returns `true` when the period at `index` in `scalars` is an abbreviation,
/// not a sentence boundary.
///
/// Mirrors Python's ``_period_is_abbreviation``.
private func periodIsAbbreviation(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
    let n = scalars.count

    // Find line start (last \n before index, exclusive)
    var lineStart = 0
    var j = index - 1
    while j >= 0 {
        if scalars[j].value == 0x0A { lineStart = j + 1; break }
        j -= 1
    }

    // Numbered-item-marker check: fullmatch \s*(?:[A-Za-z][A-Za-z ]{0,24}:\s*)?\d+\.
    // Only succeeds when the period is at exactly `index` (line_prefix ends with digit then .)
    do {
        var pi = lineStart
        // \s*
        while pi < index && isPythonWhitespace(scalars[pi]) { pi += 1 }
        // Optional speaker prefix [A-Za-z][A-Za-z ]{0,24}:\s*
        let savedPI = pi
        if pi < index && atlIsAlpha(scalars[pi].value) {
            pi += 1
            var labelLen = 0
            while pi < index && labelLen < 24 {
                let v = scalars[pi].value
                if atlIsAlpha(v) || v == 0x20 { pi += 1; labelLen += 1 } else { break }
            }
            if pi < index && scalars[pi].value == 0x3A {
                pi += 1
                while pi < index && isPythonWhitespace(scalars[pi]) { pi += 1 }
            } else {
                pi = savedPI
            }
        }
        // \d+
        let digitStart = pi
        while pi < index && atlIsDigit(scalars[pi].value) { pi += 1 }
        // \. must land at index
        if pi > digitStart && pi == index && scalars[pi].value == 0x2E {
            var fi = index + 1
            while fi < n && isPythonWhitespace(scalars[fi]) { fi += 1 }
            if fi < n { return true }
        }
    }

    // Consecutive-single-letter check: (?:\b[A-Za-z]\.){2,} ending at index
    do {
        let prefStart = max(0, index - 24)
        var singleCount = 0
        var jj = index
        while jj >= prefStart + 1 {
            if scalars[jj].value == 0x2E && atlIsAlpha(scalars[jj - 1].value) {
                let before = jj - 1
                if before == 0 || !atlIsAlpha(scalars[before - 1].value) {
                    singleCount += 1
                    jj -= 2
                } else { break }
            } else { break }
        }
        if singleCount >= 2 { return true }
    }

    // Known-abbreviation and single-letter checks
    do {
        let prefStart = max(0, index - 24)
        // Scan backward from index-1 for a word of the form [A-Za-z.]+
        var ti = index - 1
        while ti >= prefStart {
            let v = scalars[ti].value
            if atlIsAlpha(v) || v == 0x2E { ti -= 1 } else { break }
        }
        let tokenStart = ti + 1
        if tokenStart < index {
            // Build lowercase token
            var tokenSc: [Unicode.Scalar] = []
            for k in tokenStart ..< index {
                let v = scalars[k].value
                let lo = (atlIsUpper(v)) ? Unicode.Scalar(v + 0x20)! : scalars[k]
                tokenSc.append(lo)
            }
            let token = scalarsToString(tokenSc)
            if abbreviations.contains(token) { return true }
            // Single-letter base word check
            let firstPart: String
            if let dotRange = token.range(of: ".") {
                firstPart = String(token[..<dotRange.lowerBound])
            } else {
                firstPart = token
            }
            if firstPart.unicodeScalars.count == 1 {
                var fi = index + 1
                while fi < n && isPythonWhitespace(scalars[fi]) { fi += 1 }
                if fi < n && pyIsUpper(scalars[fi]) { return true }
            }
        }
    }
    return false
}

// MARK: - sentenceSpans

/// Splits `textSlice` into sentence spans.
///
/// Mirrors Python's ``_sentence_spans``.
/// Returns `(start_cp, end_cp, text_str)` where offsets are `base + local`.
func sentenceSpans(_ textSlice: [Unicode.Scalar], base: Int = 0) -> [(Int, Int, String)] {
    var spans: [(Int, Int, String)] = []
    let n = textSlice.count
    var start = 0

    func emit(from sl: Int, to el: Int) {
        var l = sl
        while l < el && isPythonWhitespace(textSlice[l]) { l += 1 }
        var r = el
        while r > l && isPythonWhitespace(textSlice[r - 1]) { r -= 1 }
        if r > l {
            spans.append((base + l, base + r, scalarsToString(textSlice, l ..< r)))
        }
    }

    for index in 0 ..< n {
        let v = textSlice[index].value

        // Newline boundary: previous visible char is sentence-ender
        if v == 0x0A {
            var prev = index - 1
            while prev >= 0 && isPythonWhitespace(textSlice[prev]) { prev -= 1 }
            if prev >= 0 {
                let pv = textSlice[prev].value
                if pv == 0x2E || pv == 0x21 || pv == 0x3F
                    || pv == 0x3002 || pv == 0xFF01 || pv == 0xFF1F {
                    emit(from: start, to: index + 1)
                    start = index + 1
                }
            }
            continue
        }

        // CJK full-width sentence enders
        if v == 0x3002 || v == 0xFF01 || v == 0xFF1F {
            emit(from: start, to: index + 1)
            start = index + 1
            continue
        }

        // ASCII sentence enders: .!? followed by space (or end), not abbreviation
        if v == 0x2E || v == 0x21 || v == 0x3F {
            let followedBySpace = (index + 1 == n || isPythonWhitespace(textSlice[index + 1]))
            let abbrev = (v == 0x2E && periodIsAbbreviation(textSlice, at: index))
            if followedBySpace && !abbrev {
                emit(from: start, to: index + 1)
                start = index + 1
            }
        }
    }

    // Trailing fragment
    if start < n { emit(from: start, to: n) }
    return spans
}

// MARK: - pipeSpans

/// Splits `textSlice` on ` | ` separators.
///
/// Mirrors Python's ``_pipe_spans``.
func pipeSpans(_ textSlice: [Unicode.Scalar], base: Int) -> [(Int, Int, String)] {
    let separators = pipeSplitREFinditer(textSlice)

    func trimmedSpan(_ l: Int, _ r: Int) -> (Int, Int, String)? {
        var tl = l
        while tl < r && isPythonWhitespace(textSlice[tl]) { tl += 1 }
        var tr = r
        while tr > tl && isPythonWhitespace(textSlice[tr - 1]) { tr -= 1 }
        guard tr > tl else { return nil }
        return (base + tl, base + tr, scalarsToString(textSlice, tl ..< tr))
    }

    if separators.isEmpty {
        return trimmedSpan(0, textSlice.count).map { [$0] } ?? []
    }

    let bounds: [Int] = [0] + separators.map(\.end)
    let ends: [Int] = separators.map(\.start) + [textSlice.count]

    return zip(bounds, ends).compactMap { trimmedSpan($0, $1) }
}

// MARK: - inlineNumberedSpans

/// Splits a line with inline ``1. 2. 3.`` lists.
///
/// Mirrors Python's ``_inline_numbered_spans``. Returns empty when < 3 markers.
func inlineNumberedSpans(_ textSlice: [Unicode.Scalar], base: Int) -> [(Int, Int, String)] {
    let markers = inlineNumberedREFinditer(textSlice)
    guard markers.count >= 3 else { return [] }

    // Python: match.start("marker") — the start of the digit run.
    // INLINE_NUMBERED_RE: (?:^|\s)(?P<marker>\d+[.)]\s+)
    // If match.start == 0 (anchored at ^), marker starts at 0.
    // Otherwise the leading \s consumed one char, so marker starts at m.start+1.
    func markerStart(_ m: MatchResult) -> Int {
        m.start == 0 ? 0 : m.start + 1
    }

    func trimmedSpan(_ l: Int, _ r: Int) -> (Int, Int, String)? {
        var tl = l
        while tl < r && isPythonWhitespace(textSlice[tl]) { tl += 1 }
        var tr = r
        while tr > tl && isPythonWhitespace(textSlice[tr - 1]) { tr -= 1 }
        guard tr > tl else { return nil }
        return (base + tl, base + tr, scalarsToString(textSlice, tl ..< tr))
    }

    var result: [(Int, Int, String)] = []

    // Prefix before first marker
    let firstMS = markerStart(markers[0])
    if firstMS > 0, let s = trimmedSpan(0, firstMS) {
        result.append(s)
    }

    // Each marker..nextMarker (or end) segment
    for (i, marker) in markers.enumerated() {
        let left = markerStart(marker)
        let right = i + 1 < markers.count ? markerStart(markers[i + 1]) : textSlice.count
        if let s = trimmedSpan(left, right) { result.append(s) }
    }
    return result
}

// MARK: - structuredAtoms

/// Builds non-overlapping, exact, indivisible document atoms.
///
/// Mirrors Python's ``_structured_atoms``.
/// Returns `(atoms, unsupportedKinds)`.
public func structuredAtoms(
    _ scalars: [Unicode.Scalar],
    start: Int = 0,
    stop: Int? = nil
) -> ([IntentAtom], [String]) {
    let stopIdx = stop ?? scalars.count
    let lines = physicalLines(scalars, start: start, stop: stopIdx)
    var atoms: [IntentAtom] = []
    var unsupported: Set<String> = []
    var index = 0

    while index < lines.count {
        let (lineStart, lineEnd, visible) = lines[index]

        // Skip blank lines
        if visible.allSatisfy({ isPythonWhitespace(Unicode.Scalar($0.asciiValue ?? 0)) }) ||
            visible.trimmingCharacters(in: .whitespaces).isEmpty {
            index += 1
            continue
        }

        let visScalars = Array(visible.unicodeScalars)

        // --- date-entry or field-entry ---
        let adjacentField: Bool = {
            for neighbor in [index - 1, index + 1] {
                guard neighbor >= 0 && neighbor < lines.count else { continue }
                let sc = Array(lines[neighbor].2.unicodeScalars)
                if !fieldLineREFinditer(sc).isEmpty { return true }
            }
            return false
        }()
        let dateEntry: Bool = {
            guard matchDateLeadAtom(visible) else { return false }
            return dateREFinditer(visScalars).count <= 1
        }()
        let fieldEntry = !fieldLineREFinditer(visScalars).isEmpty && adjacentField

        if dateEntry || fieldEntry {
            appendExactAtom(&atoms, scalars: scalars, start: lineStart, end: lineEnd,
                            kind: dateEntry ? "timeline-entry" : "field-entry")
            index += 1
            continue
        }

        // --- fenced code ---
        let fenceMatches = fenceOpenREFinditer(visScalars)
        if !fenceMatches.isEmpty, let token = fenceMatches[0].groups[0] {
            let fenceChar = token.unicodeScalars.first!.value
            var finish = index + 1
            var closed = false
            while finish < lines.count {
                if matchFenceClose(lines[finish].2, char: fenceChar) {
                    finish += 1
                    closed = true
                    break
                }
                finish += 1
            }
            let atomEnd = lines[finish > index ? finish - 1 : index].1
            if !closed { unsupported.insert("unclosed-fence") }
            appendExactAtom(&atoms, scalars: scalars, start: lineStart, end: atomEnd,
                            kind: closed ? "fenced-code" : "unsupported-unclosed-fence")
            index = finish
            continue
        }

        // --- indented code ---
        if visible.hasPrefix("    ") || visible.hasPrefix("\t") {
            var finish = index + 1
            while finish < lines.count {
                let c = lines[finish].2
                if c.trimmingCharacters(in: .whitespaces).isEmpty
                    || c.hasPrefix("    ") || c.hasPrefix("\t") {
                    finish += 1
                } else { break }
            }
            appendExactAtom(&atoms, scalars: scalars, start: lineStart, end: lines[finish - 1].1,
                            kind: "indented-code")
            index = finish
            continue
        }

        // --- heading ---
        if headingLevel(visible) != nil {
            appendExactAtom(&atoms, scalars: scalars, start: lineStart, end: lineEnd, kind: "heading")
            index += 1
            continue
        }

        // --- table ---
        if index + 1 < lines.count && visible.contains("|") {
            let nextSc = Array(lines[index + 1].2.unicodeScalars)
            if !tableSeparatorREFinditer(nextSc).isEmpty {
                var finish = index + 2
                while finish < lines.count && lines[finish].2.contains("|") { finish += 1 }
                appendExactAtom(&atoms, scalars: scalars, start: lineStart, end: lines[finish - 1].1,
                                kind: "table")
                index = finish
                continue
            }
        }

        // --- diagram ---
        if !diagramREFinditer(visScalars).isEmpty {
            var finish = index + 1
            while finish < lines.count {
                let c = lines[finish].2
                let cSc = Array(c.unicodeScalars)
                if !diagramREFinditer(cSc).isEmpty || c.trimmingCharacters(in: .whitespaces).isEmpty {
                    finish += 1
                } else { break }
            }
            appendExactAtom(&atoms, scalars: scalars, start: lineStart, end: lines[finish - 1].1,
                            kind: "diagram")
            index = finish
            continue
        }

        // --- list item ---
        if isListLine(visible) {
            let parentIndent = indentWidth(visible)
            var finish = index + 1
            while finish < lines.count {
                let c = lines[finish].2
                if isListLine(c) {
                    if indentWidth(c) <= parentIndent { break }
                    finish += 1
                } else if c.trimmingCharacters(in: .whitespaces).isEmpty
                    || c.hasPrefix("  ") || c.hasPrefix("\t") {
                    finish += 1
                } else { break }
            }
            appendExactAtom(&atoms, scalars: scalars, start: lineStart, end: lines[finish - 1].1,
                            kind: "list-item")
            index = finish
            continue
        }

        // --- paragraph (with possible sentence/pipe subdivision) ---
        var finish = index + 1
        while finish < lines.count {
            let c = lines[finish].2
            if c.trimmingCharacters(in: .whitespaces).isEmpty { break }
            let cSc = Array(c.unicodeScalars)
            if !fenceOpenREFinditer(cSc).isEmpty { break }
            if c.hasPrefix("    ") || c.hasPrefix("\t") { break }
            if headingLevel(c) != nil { break }
            if isListLine(c) { break }
            if !diagramREFinditer(cSc).isEmpty { break }
            if finish + 1 < lines.count && c.contains("|") {
                if !tableSeparatorREFinditer(Array(lines[finish + 1].2.unicodeScalars)).isEmpty { break }
            }
            finish += 1
        }
        let atomEnd = lines[finish - 1].1
        let para = Array(scalars[lineStart ..< atomEnd])
        let sSpans = sentenceSpans(para, base: lineStart)
        let pSpans = pipeSpans(para, base: lineStart)
        let subdivisions: [(Int, Int, String)] = sSpans.count > 1 ? sSpans : pSpans.count > 1 ? pSpans : []
        if !subdivisions.isEmpty {
            for (subStart, subEnd, _) in subdivisions {
                appendExactAtom(&atoms, scalars: scalars, start: subStart, end: subEnd,
                                kind: "sentence-or-entry")
            }
        } else {
            let paraStr = scalarsToString(para)
            let kind: String
            if paraStr.utf8.count > 4096 {
                unsupported.insert("oversized-unstructured-paragraph")
                kind = "unsupported-oversized-unstructured"
            } else {
                kind = "paragraph"
            }
            appendExactAtom(&atoms, scalars: scalars, start: lineStart, end: atomEnd, kind: kind)
        }
        index = finish
    }

    // Heading dependency links: content atoms depend on their nearest section heading.
    var linked: [IntentAtom] = []
    var headingStack: [(level: Int, atomID: Int)] = []

    for atom in atoms {
        var deps = atom.dependencies
        if atom.kind == "heading" {
            let level = headingLevel(atom.text) ?? 7
            while !headingStack.isEmpty && headingStack.last!.level >= level {
                headingStack.removeLast()
            }
            if let parent = headingStack.last, !deps.contains(parent.atomID) {
                deps.append(parent.atomID)
            }
            headingStack.append((level, atom.atomID))
        } else if let parent = headingStack.last, !deps.contains(parent.atomID) {
            deps.append(parent.atomID)
        }
        // Preserve first-occurrence order (dict.fromkeys in Python)
        let dedup = deps.reduce(into: [Int]()) { acc, id in
            if !acc.contains(id) { acc.append(id) }
        }
        linked.append(IntentAtom(
            atomID: atom.atomID, start: atom.start, end: atom.end,
            text: atom.text, kind: atom.kind, speaker: atom.speaker,
            dependencies: dedup, hardRequired: atom.hardRequired
        ))
    }

    return (linked, unsupported.sorted())
}

/// Returns `true` when `visible` matches a fence-close for `char`.
/// Pattern: ``^\s*{char}{3,}\s*$``
private func matchFenceClose(_ visible: String, char: UInt32) -> Bool {
    let sc = Array(visible.unicodeScalars)
    let n = sc.count
    var i = 0
    while i < n && isPythonWhitespace(sc[i]) { i += 1 }
    let fStart = i
    while i < n && sc[i].value == char { i += 1 }
    guard i - fStart >= 3 else { return false }
    while i < n && isPythonWhitespace(sc[i]) { i += 1 }
    return i == n
}

/// Returns `true` when `line` starts with a DATE_LEAD pattern.
///
/// Pattern (record_shape_classifier.py):
/// ``^\s*(?:\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2})?)?|\d{1,2}[/-]\d{1,2}[/-]\d{2,4})\b``
private func matchDateLeadAtom(_ line: String) -> Bool {
    let sc = Array(line.unicodeScalars)
    let n = sc.count
    var i = 0
    while i < n && isPythonWhitespace(sc[i]) { i += 1 }
    guard i < n && atlIsDigit(sc[i].value) else { return false }

    // ISO date: \d{4}-\d{2}-\d{2}
    var di = i
    var cnt = 0
    while di < n && atlIsDigit(sc[di].value) { di += 1; cnt += 1 }
    if cnt == 4 && di < n && sc[di].value == 0x2D {
        di += 1; cnt = 0
        while di < n && atlIsDigit(sc[di].value) { di += 1; cnt += 1 }
        if cnt == 2 && di < n && sc[di].value == 0x2D {
            di += 1; cnt = 0
            while di < n && atlIsDigit(sc[di].value) { di += 1; cnt += 1 }
            if cnt == 2 {
                var end = di
                // Optional T time
                if end < n && sc[end].value == 0x54 {
                    var ti = end + 1; cnt = 0
                    while ti < n && atlIsDigit(sc[ti].value) { ti += 1; cnt += 1 }
                    if cnt == 2 && ti < n && sc[ti].value == 0x3A {
                        ti += 1; cnt = 0
                        while ti < n && atlIsDigit(sc[ti].value) { ti += 1; cnt += 1 }
                        if cnt == 2 {
                            end = ti
                            if end < n && sc[end].value == 0x3A {
                                var si = end + 1; cnt = 0
                                while si < n && atlIsDigit(sc[si].value) { si += 1; cnt += 1 }
                                if cnt == 2 { end = si }
                            }
                        }
                    }
                }
                let afterIsNonWord = end >= n || !isPythonWordChar(sc[end])
                if afterIsNonWord { return true }
            }
        }
    }

    // Short date: \d{1,2}[/-]\d{1,2}[/-]\d{2,4}\b
    di = i; cnt = 0
    while di < n && atlIsDigit(sc[di].value) && cnt < 2 { di += 1; cnt += 1 }
    if cnt >= 1 && di < n && (sc[di].value == 0x2F || sc[di].value == 0x2D) {
        di += 1; cnt = 0
        while di < n && atlIsDigit(sc[di].value) && cnt < 2 { di += 1; cnt += 1 }
        if cnt >= 1 && di < n && (sc[di].value == 0x2F || sc[di].value == 0x2D) {
            di += 1; cnt = 0
            while di < n && atlIsDigit(sc[di].value) && cnt < 4 { di += 1; cnt += 1 }
            if cnt >= 2 {
                let afterIsNonWord = di >= n || !isPythonWordChar(sc[di])
                if afterIsNonWord { return true }
            }
        }
    }
    return false
}

// MARK: - reindexAtoms

/// Re-indexes atoms with an ID offset and optional dependency remapping.
///
/// Mirrors Python's ``_reindex_atoms``.
public func reindexAtoms(
    _ atoms: [IntentAtom],
    offset: Int = 0,
    dependencyMap: [Int: [Int]] = [:],
    hardIDs: Set<Int> = []
) -> [IntentAtom] {
    atoms.map { atom in
        let deps = (dependencyMap[atom.atomID] ?? atom.dependencies).map { $0 + offset }
        return IntentAtom(
            atomID: atom.atomID + offset,
            start: atom.start, end: atom.end,
            text: atom.text, kind: atom.kind, speaker: atom.speaker,
            dependencies: deps,
            hardRequired: atom.hardRequired || hardIDs.contains(atom.atomID)
        )
    }
}

// MARK: - normalizedTerms

/// Returns stemmed, stopword-filtered terms from `text`.
///
/// Mirrors Python's ``_normalized_terms``.
public func normalizedTerms(_ text: String) -> [String] {
    let sc = Array(text.unicodeScalars)
    // Lowercase before passing to wordREFinditer
    let lowSc = pyLower(sc)
    let matches = wordREFinditer(lowSc)
    var terms: [String] = []
    for m in matches {
        var word = scalarsToString(lowSc, m.start ..< m.end)
        if scoringStopwords.contains(word) || word.unicodeScalars.count < 2 { continue }
        for suffix in ["ing", "ed", "es", "s"] {
            if word.hasSuffix(suffix) && word.unicodeScalars.count > suffix.unicodeScalars.count + 3 {
                word = String(word.dropLast(suffix.unicodeScalars.count))
                break
            }
        }
        terms.append(word)
    }
    return terms
}

// MARK: - turnBody / substantiveTurn / shortOperative

/// Returns the body text of a turn (stripped).
private func turnBody(scalars: [Unicode.Scalar], turn: SpeakerTurn) -> String {
    scalarsToString(pyStrip(Array(scalars[turn.bodyStart ..< turn.end])))
}

/// Returns `true` when a turn has substantive content.
///
/// Mirrors Python's ``_substantive_turn``.
private func substantiveTurn(scalars: [Unicode.Scalar], turn: SpeakerTurn) -> Bool {
    let body = turnBody(scalars: scalars, turn: turn)
    guard !body.isEmpty else { return false }
    let bodySc = Array(body.unicodeScalars)
    let len = bodySc.count
    // TURN_FILLER_RE fullmatch
    let filler = turnFillerREFinditer(bodySc)
    if !filler.isEmpty && filler[0].start == 0 && filler[0].end == len { return false }
    // ASSISTANT_BOILERPLATE_RE fullmatch
    let boilerplate = assistantBoilerplateREFinditer(bodySc)
    if !boilerplate.isEmpty && boilerplate[0].start == 0 && boilerplate[0].end == len { return false }
    return true
}

/// Returns `true` when `text` is a short operative request (≤ 280 UTF-8 bytes).
///
/// Mirrors Python's ``_short_operative``.
private func shortOperative(_ text: String) -> Bool {
    let body = text.trimmingCharacters(in: .whitespaces)
    guard !body.isEmpty, body.utf8.count <= 280 else { return false }
    if body.contains("?") { return true }
    return !operativeREFinditer(Array(body.unicodeScalars)).isEmpty
}

// MARK: - queryTerms / atomTerms

/// Returns query-stopword-filtered normalized terms for `text`.
private func queryTerms(_ text: String) -> Set<String> {
    Set(normalizedTerms(text).filter { $0.unicodeScalars.count >= 3 && !queryStopwords.contains($0) })
}

/// Returns the set of normalized terms for an atom's text.
private func atomTerms(_ atom: IntentAtom) -> Set<String> {
    Set(normalizedTerms(atom.text))
}

// MARK: - embeddedUserFactAtoms

/// Recovers user facts embedded after assistant scaffolding on one line.
///
/// Mirrors Python's ``_embedded_user_fact_atoms``.
private func embeddedUserFactAtoms(_ scalars: [Unicode.Scalar]) -> [IntentAtom] {
    var factSpans: [(Int, Int)] = []
    var assistantSpans: [(Int, Int)] = []
    var otherSpans: [(Int, Int)] = []
    var prefixSpans: [(Int, Int)] = []
    var eligibleLines = 0
    var assistantScaffoldLines = 0
    var otherLines = 0
    var fenceChar: UInt32? = nil
    var sawFence = false

    for (lineStart, _, visible) in physicalLines(scalars) {
        let visSc = Array(visible.unicodeScalars)
        // visibleLen is the code-point count of the visible text (no \r\n).
        // Python: line_start + len(visible) — visible here is stripped of \r\n.
        let visibleLen = visSc.count
        let visibleEnd = lineStart + visibleLen  // mirrors Python: line_start + len(visible)

        let fenceMatches = fenceOpenREFinditer(visSc)
        if !fenceMatches.isEmpty {
            sawFence = true
            if let token = fenceMatches[0].groups[0] {
                let marker = token.unicodeScalars.first!.value
                if fenceChar == nil { fenceChar = marker }
                else if marker == fenceChar { fenceChar = nil }
            }
            continue
        }
        if fenceChar != nil || visible.trimmingCharacters(in: .whitespaces).isEmpty { continue }
        eligibleLines += 1

        let factMatches = embeddedUserFactREFinditer(visSc)
        if let fm = factMatches.first, let factText = fm.groups[0] {
            let factSc = Array(factText.unicodeScalars)
            // Find the offset of the fact group within visSc starting at fm.start.
            // Python: start, end = match.span("fact")
            var factOffset = fm.start
            outer: for fi in fm.start ..< min(fm.end, visSc.count - factSc.count + 1) {
                guard fi + factSc.count <= visSc.count else { break }
                for k in 0 ..< factSc.count {
                    if visSc[fi + k] != factSc[k] { continue outer }
                }
                factOffset = fi
                break
            }
            let gStart = lineStart + factOffset
            let gEnd = gStart + factSc.count
            // Prefix: visible[:start].rstrip() — Python: prefix_end = len(prefix.rstrip())
            var prefEnd = factOffset
            while prefEnd > 0 && isPythonWhitespace(visSc[prefEnd - 1]) { prefEnd -= 1 }
            if prefEnd > 0 { prefixSpans.append((lineStart, lineStart + prefEnd)) }
            factSpans.append((gStart, gEnd))
        } else if let (speaker, _) = knownSpeakerAtom(visible), knownAnswerSpeakers.contains(speaker) {
            // Python: assistant_spans.append((line_start, line_start + len(visible)))
            assistantScaffoldLines += 1
            assistantSpans.append((lineStart, visibleEnd))
        } else {
            // Python: other_spans.append((line_start, line_start + len(visible)))
            otherLines += 1
            otherSpans.append((lineStart, visibleEnd))
        }
    }

    // Reject non-embedded-transcript shapes
    if sawFence || factSpans.count < 4 || otherLines > 2
        || abs(assistantScaffoldLines - factSpans.count) > 1
        || factSpans.count * 2 < eligibleLines - 2 {
        return []
    }

    // Build atoms sorted by start position
    var inventory: [(Int, Int, String, String?, Bool)] = []
    for (s, e) in factSpans { inventory.append((s, e, "embedded-timestamped-user-fact", "user", true)) }
    for (s, e) in assistantSpans { inventory.append((s, e, "embedded-assistant-turn", "assistant", false)) }
    for (s, e) in otherSpans { inventory.append((s, e, "embedded-context-line", nil, false)) }
    for (s, e) in prefixSpans { inventory.append((s, e, "embedded-line-prefix", nil, false)) }
    inventory.sort { $0.0 < $1.0 }

    var atoms: [IntentAtom] = []
    for (s, e, kind, speaker, required) in inventory {
        appendExactAtom(&atoms, scalars: scalars, start: s, end: e,
                        kind: kind, speaker: speaker, hardRequired: required)
    }
    return atoms
}

// MARK: - findDocumentExchange

/// Detects a user-supplies-document → assistant-transforms pattern.
///
/// Mirrors Python's ``_find_document_exchange``.
private func findDocumentExchange(
    scalars: [Unicode.Scalar],
    turns: [SpeakerTurn]
) -> (requestTurn: SpeakerTurn, documentStart: Int, answerTurn: SpeakerTurn)? {
    for (index, turn) in turns.enumerated() {
        guard knownUserSpeakers.contains(turn.speaker) else { continue }
        let firstBody = scalarsToString(pyStrip(Array(scalars[turn.bodyStart ..< turn.firstLineEnd])))
        guard shortOperative(firstBody) else { continue }
        let continuationStart = turn.firstLineEnd
        let answers = turns[(index + 1)...].filter {
            knownAnswerSpeakers.contains($0.speaker) && substantiveTurn(scalars: scalars, turn: $0)
        }
        guard let answer = answers.last else { continue }
        let continuation = scalarsToString(Array(scalars[continuationStart ..< answer.start]))
        guard continuation.utf8.count >= 800 else { continue }
        let immediatePayload = scalarsToString(Array(scalars[continuationStart ..< turn.end]))
        guard immediatePayload.utf8.count >= 800 else { continue }
        return (turn, continuationStart, answer)
    }
    return nil
}

// MARK: - appendAnswerSubatoms

/// Appends exact semantic subunits for one substantive answer turn.
///
/// Mirrors Python's ``_append_answer_subatoms``.
/// Returns `(addedIDs, unsupportedKinds)`.
private func appendAnswerSubatoms(
    _ atoms: inout [IntentAtom],
    scalars: [Unicode.Scalar],
    turn: SpeakerTurn,
    dependencies: [Int]
) -> ([Int], [String]) {
    let (parts, unsupported) = structuredAtoms(scalars, start: turn.start, stop: turn.end)
    var ids: [Int] = []
    let baseID = atoms.count

    for (partIndex, part) in parts.enumerated() {
        let partDeps = part.dependencies.map { baseID + $0 }
        var partKind = part.kind
        if partIndex == 0, let (_, bodyOff) = knownSpeakerAtom(part.text) {
            let afterLabel = String(part.text.unicodeScalars.dropFirst(bodyOff))
            if isListLine(afterLabel) { partKind = "list-item" }
        }
        // Merge turn-level dependencies (order-preserving dedup)
        var allDeps = dependencies
        for dep in partDeps { if !allDeps.contains(dep) { allDeps.append(dep) } }

        let atom = appendExactAtom(
            &atoms, scalars: scalars, start: part.start, end: part.end,
            kind: "answer-\(partKind)", speaker: turn.speaker,
            dependencies: allDeps, hardRequired: false
        )
        ids.append(atom.atomID)
    }

    if ids.isEmpty {
        let atom = appendExactAtom(
            &atoms, scalars: scalars, start: turn.start, end: turn.end,
            kind: "answer-turn", speaker: turn.speaker,
            dependencies: dependencies, hardRequired: false
        )
        ids.append(atom.atomID)
    }
    return (ids, unsupported)
}

// MARK: - normalizedAtomText

/// Returns normalized text for deduplication.
///
/// Mirrors Python's ``_normalized_atom_text``.
private func normalizedAtomText(_ atom: IntentAtom) -> String {
    var text = atom.text
    if atom.kind == "list-item" || atom.kind == "answer-list-item" {
        if atom.kind == "answer-list-item" {
            if let (_, bodyOff) = knownSpeakerAtom(text) {
                text = String(text.unicodeScalars.dropFirst(bodyOff))
            }
        }
        let sc = Array(text.unicodeScalars)
        let markerMatches = listMarkerREFinditer(sc)
        if !markerMatches.isEmpty {
            text = scalarsToString(sc, markerMatches[0].end ..< sc.count)
        }
    }
    // re.sub(r"\s+", " ", text).strip().casefold()
    var collapsed = ""
    var lastWasSpace = false
    for s in text.unicodeScalars {
        if isPythonWhitespace(s) {
            if !lastWasSpace { collapsed += " " }
            lastWasSpace = true
        } else {
            collapsed.unicodeScalars.append(s)
            lastWasSpace = false
        }
    }
    return collapsed.trimmingCharacters(in: .whitespaces).lowercased()
}

// MARK: - distinctAnswerIDs

/// Returns de-duplicated answer IDs (by normalized text).
private func distinctAnswerIDs(atoms: [IntentAtom], answerIDs: [Int]) -> [Int] {
    var seen = Set<String>()
    return answerIDs.filter { id in
        guard id < atoms.count else { return false }
        let norm = normalizedAtomText(atoms[id])
        return seen.insert(norm).inserted
    }
}

// MARK: - intentRelevance

/// Scores an atom by its relevance for intent-span selection.
///
/// Mirrors Python's ``_intent_relevance``.
private func intentRelevance(_ atom: IntentAtom) -> Int {
    let terms = atomTerms(atom)
    let sc = Array(atom.text.unicodeScalars)
    var score = terms.count * 10
    score += dateREFinditer(sc).count * 160
    score += numberREFinditer(sc).count * 100
    score += terms.filter { actionStems.contains($0) }.count * 140
    let kindBonus: [String: Int] = [
        "fenced-code": 300, "indented-code": 300, "table": 280,
        "diagram": 240, "list-item": 220, "heading": 180,
        "answer-fenced-code": 300, "answer-indented-code": 300,
        "answer-table": 280, "answer-diagram": 240,
        "answer-list-item": 220, "answer-heading": 180,
    ]
    score += kindBonus[atom.kind] ?? 0
    return score
}

// MARK: - answerCoverageIDs

/// Returns deterministic topical coverage for a substantive answer.
///
/// Mirrors Python's ``_answer_coverage_ids``.
private func answerCoverageIDs(atoms: [IntentAtom], answerIDs: [Int]) -> Set<Int> {
    let distinct = distinctAnswerIDs(atoms: atoms, answerIDs: answerIDs)
    let candidates = distinct.filter { atoms[$0].kind != "answer-heading" }
    guard !candidates.isEmpty else { return [] }

    // max(candidates, key=lambda id: (relevance, -start))
    let best = candidates.max { a, b in
        let ra = intentRelevance(atoms[a])
        let rb = intentRelevance(atoms[b])
        if ra != rb { return ra < rb }
        return atoms[a].start > atoms[b].start
    }!
    var covered: Set<Int> = [best]

    // All list items
    for id in candidates where atoms[id].kind == "answer-list-item" { covered.insert(id) }

    // Best child of each heading
    for headingID in answerIDs where atoms[headingID].kind == "answer-heading" {
        let children = candidates.filter { atoms[$0].dependencies.contains(headingID) }
        if let bestChild = children.max(by: {
            let ra = intentRelevance(atoms[$0])
            let rb = intentRelevance(atoms[$1])
            return ra != rb ? ra < rb : atoms[$0].start > atoms[$1].start
        }) {
            covered.insert(bestChild)
        }
    }
    return covered
}

// MARK: - IntentAtomsResult

/// Result of ``intentAtoms(_:)``.
///
/// `@unchecked Sendable` because `modeExtras` is `[String: Any]` (Foundation types,
/// all immutable after construction).  The value is never mutated after init.
public struct IntentAtomsResult: @unchecked Sendable {
    /// All atoms produced for the source.
    public let atoms: [IntentAtom]
    /// Atom IDs that must appear in the output unconditionally.
    public let hardIDs: Set<Int>
    /// Atom IDs required for query-term coverage.
    public let coverageIDs: Set<Int>
    /// Unsupported shape descriptions encountered.
    public let unsupported: [String]
    /// Mode string: "document", "genuine-dialogue", "document-exchange",
    /// or "embedded-transcript".
    public let mode: String
    /// Mode-specific extra fields spread into ``selection_details``.
    ///
    /// Mirrors the extra keys Python's ``_intent_atoms`` returns in its 5th element:
    /// - "embedded-transcript": embedded_user_fact_count, embedded_assistant_turn_count,
    ///   embedded_context_line_count, embedded_line_prefix_count
    /// - "document-exchange": query_terms ([String]), protected_document_structure (Bool),
    ///   derived_answer_omitted ([String: Any])
    /// - "genuine-dialogue": discarded_turns ([[String: Any]])
    /// - "document": (empty)
    public let modeExtras: [String: Any]
}

// MARK: - intentAtoms

/// Builds atoms, hard IDs, coverage IDs, unsupported shapes, and mode for `source`.
///
/// This is the main entry point, mirroring Python's ``_intent_atoms``.
///
/// - Parameter scalars: The full source string as a Unicode scalar array.
/// - Returns: An ``IntentAtomsResult`` with all atoms and classification metadata.
public func intentAtoms(
    _ scalars: [Unicode.Scalar],
    peerDialogue: Bool = false
) -> IntentAtomsResult {

    // --- embedded-transcript path ---
    let embeddedFacts = embeddedUserFactAtoms(scalars)
    if !embeddedFacts.isEmpty {
        let hard = Set(embeddedFacts.filter(\.hardRequired).map(\.atomID))
        // Mirror Python: mode_details dict for embedded-transcript.
        let extras: [String: Any] = [
            "embedded_user_fact_count": hard.count,
            "embedded_assistant_turn_count": embeddedFacts.filter { $0.kind == "embedded-assistant-turn" }.count,
            "embedded_context_line_count": embeddedFacts.filter { $0.kind == "embedded-context-line" }.count,
            "embedded_line_prefix_count": embeddedFacts.filter { $0.kind == "embedded-line-prefix" }.count,
        ]
        return IntentAtomsResult(
            atoms: embeddedFacts,
            hardIDs: hard,
            coverageIDs: [],
            unsupported: [],
            mode: "embedded-transcript",
            modeExtras: extras
        )
    }

    let turns = speakerTurns(scalars)

    // --- document-exchange path ---
    if let exchange = findDocumentExchange(scalars: scalars, turns: turns) {
        let (requestTurn, documentStart, answerTurn) = exchange
        var atoms: [IntentAtom] = []
        let request = appendExactAtom(
            &atoms, scalars: scalars,
            start: requestTurn.start, end: requestTurn.firstLineEnd,
            kind: "operative-request", speaker: requestTurn.speaker,
            hardRequired: true
        )
        let (docAtoms, unsupported) = structuredAtoms(scalars, start: documentStart, stop: answerTurn.start)
        atoms.append(contentsOf: reindexAtoms(docAtoms, offset: atoms.count))

        let queryText = scalarsToString(Array(scalars[requestTurn.bodyStart ..< requestTurn.firstLineEnd]))
        let query = queryTerms(queryText)
        let documentIDs = Set(atoms.filter { documentStart <= $0.start && $0.start < answerTurn.start }.map(\.atomID))
        var coverage = Set<Int>()
        for term in query.sorted() {
            if let best = atoms.filter({
                documentIDs.contains($0.atomID) && $0.kind != "heading"
                && atomTerms($0).contains(term)
            }).min(by: {
                $0.text.utf8.count != $1.text.utf8.count
                    ? $0.text.utf8.count < $1.text.utf8.count
                    : $0.start < $1.start
            }) {
                coverage.insert(best.atomID)
            }
        }
        // Mirror Python: protected_document_structure check (any structured atom in document).
        let protectedDocument = docAtoms.contains { atom in
            ["fenced-code", "indented-code", "table", "diagram", "list-item",
             "unsupported-unclosed-fence", "unsupported-oversized-unstructured"].contains(atom.kind)
        }
        // Mirror Python: derived_answer_omitted dict for document-exchange mode.
        let derivedAnswerOmitted: [String: Any] = [
            "start": answerTurn.start,
            "end": answerTurn.end,
            "speaker": answerTurn.speaker,
            "reason": "generated-transform-not-source-evidence",
        ]
        let extras: [String: Any] = [
            "query_terms": query.sorted(),
            "protected_document_structure": protectedDocument,
            "derived_answer_omitted": derivedAnswerOmitted,
        ]
        return IntentAtomsResult(
            atoms: atoms,
            hardIDs: [request.atomID],
            coverageIDs: coverage,
            unsupported: unsupported,
            mode: "document-exchange",
            modeExtras: extras
        )
    }

    // --- named-peer dialogue path (v23.2 attributed prose) ---
    if peerDialogue {
        let peerTurns = peerSpeakerTurns(scalars)
        if !peerTurns.isEmpty {
            var atoms: [IntentAtom] = []
            var unsupported: [String] = []
            var discardedTurns: [[String: Any]] = []

            for turn in peerTurns {
                let body = turnBody(scalars: scalars, turn: turn)
                let bodyScalars = Array(body.unicodeScalars)
                let turnFiller = turnFillerREFinditer(bodyScalars)
                let greetingOnly = greetingOnlyREFinditer(bodyScalars)
                let dialogueFiller = dialogueFillerOnlyREFinditer(bodyScalars)
                let isFiller = body.isEmpty
                    || (turnFiller.first?.start == 0 && turnFiller.first?.end == bodyScalars.count)
                    || (greetingOnly.first?.start == 0 && greetingOnly.first?.end == bodyScalars.count)
                    || (dialogueFiller.first?.start == 0 && dialogueFiller.first?.end == bodyScalars.count)

                if isFiller {
                    discardedTurns.append([
                        "speaker": turn.speaker,
                        "start": turn.start,
                        "reason": "filler",
                    ])
                    continue
                }

                let prefix = appendExactAtom(
                    &atoms, scalars: scalars,
                    start: turn.start, end: turn.bodyStart,
                    kind: "peer-speaker-prefix", speaker: turn.speaker
                )
                let (parts, problems) = structuredAtoms(
                    scalars, start: turn.bodyStart, stop: turn.end)
                unsupported.append(contentsOf: problems)

                if parts.isEmpty {
                    appendExactAtom(
                        &atoms, scalars: scalars,
                        start: turn.bodyStart, end: turn.end,
                        kind: "peer-dialogue-turn", speaker: turn.speaker,
                        dependencies: [prefix.atomID]
                    )
                    continue
                }

                let baseID = atoms.count
                for part in parts {
                    var dependencies = [prefix.atomID]
                    for dependency in part.dependencies.map({ baseID + $0 })
                        where !dependencies.contains(dependency) {
                        dependencies.append(dependency)
                    }
                    appendExactAtom(
                        &atoms, scalars: scalars,
                        start: part.start, end: part.end,
                        kind: "peer-\(part.kind)", speaker: turn.speaker,
                        dependencies: dependencies
                    )
                }
            }

            if atoms.contains(where: { $0.kind != "peer-speaker-prefix" }) {
                let extras: [String: Any] = [
                    "peer_speakers": Set(peerTurns.map(\.speaker)).sorted(),
                    "peer_turn_count": peerTurns.count,
                    "discarded_turns": discardedTurns,
                ]
                return IntentAtomsResult(
                    atoms: atoms,
                    hardIDs: [],
                    coverageIDs: [],
                    unsupported: Array(Set(unsupported)).sorted(),
                    mode: "peer-dialogue",
                    modeExtras: extras
                )
            }
        }
    }

    // --- genuine-dialogue path ---
    if turns.count >= 2 {
        var atoms: [IntentAtom] = []
        var hard = Set<Int>()
        var coverage = Set<Int>()
        var unsupported: [String] = []
        var turnAtomIDs: [Int: [Int]] = [:]
        var consumedAnswers = Set<Int>()
        // Mirror Python: track non-substantive user turns for mode_details.discarded_turns.
        var discardedTurns: [[String: Any]] = []

        let substantiveUserIndexes = turns.indices.filter {
            knownUserSpeakers.contains(turns[$0].speaker)
            && substantiveTurn(scalars: scalars, turn: turns[$0])
        }
        let lastSubstantiveUser = substantiveUserIndexes.last

        // Prefix context (content before first turn)
        if turns[0].start > 0 {
            let prefixStr = scalarsToString(Array(scalars[0 ..< turns[0].start]))
            if !prefixStr.trimmingCharacters(in: .whitespaces).isEmpty {
                let a = appendExactAtom(
                    &atoms, scalars: scalars, start: 0, end: turns[0].start,
                    kind: "dialogue-prefix-context", hardRequired: true
                )
                hard.insert(a.atomID)
            }
        }

        for (index, turn) in turns.enumerated() {
            guard knownUserSpeakers.contains(turn.speaker) else { continue }
            // Mirror Python: non-substantive user turns are discarded (filler).
            guard substantiveTurn(scalars: scalars, turn: turn) else {
                discardedTurns.append([
                    "speaker": turn.speaker,
                    "start": turn.start,
                    "reason": "filler",
                ])
                continue
            }

            var dependencies: [Int] = []
            let userBody = turnBody(scalars: scalars, turn: turn)
            let userBodySc = Array(userBody.unicodeScalars)

            // Check if context from previous answer turn is needed.
            // Mirror Python: POLARITY_ONLY_RE fullmatch, 160-byte context, 280-byte transform.
            if index > 0 {
                let contextTurn = turns[index - 1]
                let contextBody = turnBody(scalars: scalars, turn: contextTurn)

                let polarityOnly: Bool = {
                    let matches = polarityOnlyREFinditer(userBodySc)
                    return !matches.isEmpty && matches[0].start == 0 && matches[0].end == userBodySc.count
                }()
                let contextNeeded: Bool = {
                    if polarityOnly { return true }
                    if userBody.utf8.count <= 160 && contextBody.contains("?") { return true }
                    // TRANSFORM_FOLLOWUP_RE.search(user_body) — search anywhere.
                    if userBody.utf8.count <= 280 && !transformFollowupREFinditer(userBodySc).isEmpty { return true }
                    return false
                }()

                if contextNeeded && knownAnswerSpeakers.contains(contextTurn.speaker)
                    && substantiveTurn(scalars: scalars, turn: contextTurn) {
                    if turnAtomIDs[index - 1] == nil {
                        let (ids, problems) = appendAnswerSubatoms(
                            &atoms, scalars: scalars, turn: contextTurn, dependencies: [])
                        unsupported.append(contentsOf: problems)
                        turnAtomIDs[index - 1] = ids
                    }
                    hard.formUnion(turnAtomIDs[index - 1]!)
                    dependencies = turnAtomIDs[index - 1]!
                }
            }

            let userAtom = appendExactAtom(
                &atoms, scalars: scalars, start: turn.start, end: turn.end,
                kind: "substantive-user-turn", speaker: turn.speaker,
                dependencies: dependencies, hardRequired: true
            )
            turnAtomIDs[index] = [userAtom.atomID]
            hard.insert(userAtom.atomID)

            // Find paired answer turns
            var answerIndexes: [Int] = []
            for answerIndex in (index + 1) ..< turns.count {
                let at = turns[answerIndex]
                if knownUserSpeakers.contains(at.speaker) { break }
                if !consumedAnswers.contains(answerIndex)
                    && knownAnswerSpeakers.contains(at.speaker)
                    && substantiveTurn(scalars: scalars, turn: at) {
                    answerIndexes.append(answerIndex)
                }
            }

            // Mirror Python: active_answer uses REVISION_MARKER_RE.search (not TRANSFORM_FOLLOWUP_RE).
            // OPERATIVE_RE.match is anchored at ^ — operativeREFinditer handles that.
            let activeAnswer: Bool = {
                guard index == lastSubstantiveUser else { return false }
                if userBody.contains("?") { return true }
                if !operativeREFinditer(userBodySc).isEmpty { return true }
                if !revisionMarkerREFinditer(userBodySc).isEmpty { return true }
                return false
            }()

            for pairedAnswerIndex in answerIndexes {
                let at = turns[pairedAnswerIndex]
                if turnAtomIDs[pairedAnswerIndex] == nil {
                    let (ids, problems) = appendAnswerSubatoms(
                        &atoms, scalars: scalars, turn: at,
                        dependencies: [userAtom.atomID])
                    unsupported.append(contentsOf: problems)
                    turnAtomIDs[pairedAnswerIndex] = ids
                }
                let answerIDs = turnAtomIDs[pairedAnswerIndex]!
                coverage.formUnion(answerCoverageIDs(atoms: atoms, answerIDs: answerIDs))
                if activeAnswer {
                    hard.formUnion(distinctAnswerIDs(atoms: atoms, answerIDs: answerIDs))
                }
                consumedAnswers.insert(pairedAnswerIndex)
            }
        }

        // Unclaimed substantive answer turns
        for (index, turn) in turns.enumerated() {
            if turnAtomIDs[index] == nil
                && knownAnswerSpeakers.contains(turn.speaker)
                && substantiveTurn(scalars: scalars, turn: turn) {
                let (ids, problems) = appendAnswerSubatoms(
                    &atoms, scalars: scalars, turn: turn, dependencies: [])
                unsupported.append(contentsOf: problems)
                turnAtomIDs[index] = ids
            }
        }

        if !atoms.isEmpty {
            let extras: [String: Any] = ["discarded_turns": discardedTurns]
            return IntentAtomsResult(
                atoms: atoms,
                hardIDs: hard,
                coverageIDs: coverage,
                unsupported: unsupported.sorted(),
                mode: "genuine-dialogue",
                modeExtras: extras
            )
        }
    }

    // --- document path ---
    let (atoms, unsupported) = structuredAtoms(scalars)
    return IntentAtomsResult(
        atoms: atoms,
        hardIDs: [],
        coverageIDs: [],
        unsupported: unsupported,
        mode: "document",
        modeExtras: [:]
    )
}

// MARK: - Convenience overloads (String input)

/// Convenience: build speaker turns from a `String`.
public func speakerTurns(_ source: String) -> [SpeakerTurn] {
    speakerTurns(Array(source.unicodeScalars))
}

/// Convenience: build structured atoms from a `String`.
public func structuredAtoms(_ source: String) -> ([IntentAtom], [String]) {
    structuredAtoms(Array(source.unicodeScalars))
}

/// Convenience: build intent atoms from a `String`.
public func intentAtoms(_ source: String) -> IntentAtomsResult {
    intentAtoms(Array(source.unicodeScalars))
}
