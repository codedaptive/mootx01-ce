// SelectionLayer.swift
// Port of the intent-span selection layer from distill_plus_converter.py.
//
// Public entry points:
//   intentSpan(_:trailer:)           — mirrors intent_span (without _combine)
//   dependencyClosure(atomByID:initial:) — mirrors _dependency_closure
//   selectionBytes(scalars:atoms:selected:) — mirrors _selection_bytes
//   renderExact(scalars:atoms:selected:hardIDs:) — mirrors _render_exact
//   portableSpanOffsets(scalars:spans:) — mirrors _portable_span_offsets
//   sourceOccurrences(scalars:value:) — mirrors _source_occurrences
//   sentenceInitial(scalars:start:) — mirrors _sentence_initial
//   projectIntentTrailer(scalars:trailer:) — mirrors project_intent_trailer
//
// Design rules (from the decision record):
//   - NO regex engine. All pattern matching is hand-written character scanners.
//   - Index unit: unicodeScalars (code points). Python str indices are code points.
//   - Python integer semantics: truncating division (same as Swift for non-negative).
//   - Stable sort: Swift sorted() is stable, matching Python.
//   - No Date(), no randomness. Pure functions.
//
// Part 4 scope: produces (core text, selected_source_spans, selection_details
// minus trailer_projection). The trailer_projection field is computed here for
// correct budget math but excluded from the Part 4 public output struct.
// Part 5 will expose it as part of the full converter output.

import Foundation

@inline(__always) private func atlSelectionIsAlpha(_ value: UInt32) -> Bool {
    (value >= 0x41 && value <= 0x5A) || (value >= 0x61 && value <= 0x7A)
}

// MARK: - Constants (mirrors Python constants)

private let intentSpanVersion = "intent-span-v22-authority-closure"

/// Trailer delimiters (mirrors TRAILER_RE grammar).
/// Trailer format: (*[ field: value, ... ]*)
private let trailerOpenPrefix = "(*["
private let trailerClosePrefix = "]*)"

// Supported trailer label types (mirrors project_intent_trailer).
private let supportedFieldLabels: Set<String> = ["entity", "place", "country", "date", "quantity"]
private let opaqueLabels: Set<String> = ["kind", "fdc"]

// Entity non-name values and prefixes (mirrors Python constants).
private let entityNonNameValues: Set<String> = [
    "absolutely", "acknowledged", "certainly", "correct", "exactly",
    "got it", "great", "hello", "no", "noted", "okay", "perfect",
    "received", "right", "sounds good", "sure", "thanks",
    "thank you", "understood", "yes", "you're welcome", "you are welcome",
]
private let entityNonNamePrefixes: Set<String> = [
    "analyze", "answer", "check", "compare", "convert", "describe",
    "determine", "explain", "extract", "find", "identify", "list",
    "please", "provide", "review", "show", "summarize", "tell", "verify",
    "write",
]

// Locative and entity cue keyword lists (mirrors Python regex groups).
private let locativeCueWords: [String] = [
    "in", "at", "from", "to", "near", "around", "inside", "outside",
    "visited", "visiting", "located", "based", "lives", "lived", "moved",
    "travelled", "traveled", "traveling",
]
private let entityCueWords: [String] = [
    "called", "named", "project", "company", "person", "store", "city", "brand", "organization",
]
private let entitySubjectCueWords: [String] = [
    "agreed", "approved", "asked", "attended", "bought", "chose", "decided",
    "discovered", "joined", "lives", "moved", "ordered", "owns", "planned",
    "prefers", "said", "shipped", "works",
]

// MARK: - IntentSpanResult

/// Result of ``intentSpan(_:trailer:)``.
///
/// `@unchecked Sendable` because `selectedSpans` and `selectionDetails` use
/// Foundation's `[String: Any]` which is not natively Sendable.
public struct IntentSpanResult: @unchecked Sendable {
    /// The concatenated core text (exact source atoms, whitespace-preserved).
    /// Mirrors Python: core (return value index 0 of intent_span).
    public let core: String

    /// Per-span metadata, one dict per selected atom, in source order.
    /// Includes atom_id, start, end, kind, speaker, dependencies,
    /// hard_required, start_utf8_byte, end_utf8_byte.
    /// Mirrors Python: _portable_span_offsets(source, spans).
    public let selectedSpans: [[String: Any]]

    /// Selection metadata dict, including trailer_projection.
    /// Mirrors Python: details dict returned by intent_span.
    public let selectionDetails: [String: Any]

    /// The source-projected trailer string (may be empty).
    /// Mirrors Python: projected_trailer (return value index 3 of intent_span).
    /// Used by ContextDistiller to assemble ai_text and mining_body via _combine.
    public let projectedTrailer: String
}

// MARK: - dependencyClosure

/// Returns the transitive dependency closure of `initial` atom IDs.
///
/// Mirrors Python's ``_dependency_closure``.
public func dependencyClosure(
    atomByID: [Int: IntentAtom],
    initial: Set<Int>
) -> Set<Int> {
    var closure = initial
    var stack = Array(initial)
    while !stack.isEmpty {
        let id = stack.removeLast()
        guard let atom = atomByID[id] else { continue }
        for dep in atom.dependencies where !closure.contains(dep) {
            closure.insert(dep)
            stack.append(dep)
        }
    }
    return closure
}

// MARK: - overlapPermille

/// Returns the Jaccard overlap in permille (0-1000) between two term sets.
///
/// Mirrors Python's ``_overlap_permille``.
/// Python integer division (//) is truncating — same as Swift / for non-negative ints.
func overlapPermille(_ left: Set<String>, _ right: Set<String>) -> Int {
    guard !left.isEmpty, !right.isEmpty else { return 0 }
    return left.intersection(right).count * 1000 / left.union(right).count
}

// MARK: - selectionBytes

/// Computes the byte size of a candidate selection, including inter-atom gaps.
///
/// Gaps of pure whitespace contribute their literal byte count; gaps with
/// non-whitespace content contribute 2 bytes (the "\n\n" separator renderExact
/// will insert there).
///
/// Mirrors Python's ``_selection_bytes``.
public func selectionBytes(
    scalars: [Unicode.Scalar],
    atoms: [IntentAtom],
    selected: Set<Int>
) -> Int {
    let chosen = atoms.filter { selected.contains($0.atomID) }
        .sorted { $0.start < $1.start }
    guard !chosen.isEmpty else { return 0 }
    // Sum atom UTF-8 bytes.
    var size = chosen.reduce(0) { $0 + $1.text.utf8.count }
    // Add inter-atom gap bytes.
    for (left, right) in zip(chosen, chosen.dropFirst()) {
        // Gap is the literal scalars between left.end and right.start.
        let gapScalars = Array(scalars[left.end ..< right.start])
        // Mirror Python: if not gap.strip() use len(gap.encode("utf-8")) else 2.
        // isPythonWhitespace matches Python str.strip() semantics.
        let gapIsWhitespace = gapScalars.allSatisfy { isPythonWhitespace($0) }
        if gapIsWhitespace {
            // Literal byte count of the whitespace gap.
            var gapBytes = 0
            for sc in gapScalars { gapBytes += sc.utf8.count }
            size += gapBytes
        } else {
            // Non-whitespace gap collapses to "\n\n" (2 bytes).
            size += 2
        }
    }
    return size
}

// MARK: - renderExact

/// Renders selected atoms as a concatenated string, inserting gaps.
///
/// Gap policy: pure-whitespace gaps are preserved verbatim; non-whitespace
/// gaps become "\n\n".
///
/// Mirrors Python's ``_render_exact``.
/// Returns `(core, spans)` where spans are `[String: Any]` dicts with
/// atom_id, start, end, kind, speaker, dependencies, hard_required.
/// (UTF-8 byte offsets are added separately by portableSpanOffsets.)
public func renderExact(
    scalars: [Unicode.Scalar],
    atoms: [IntentAtom],
    selected: Set<Int>,
    hardIDs: Set<Int> = []
) -> (String, [[String: Any]]) {
    // Sort by (start, end) — mirrors Python's `sorted(..., key=lambda a: (a.start, a.end))`.
    let chosen = atoms.filter { selected.contains($0.atomID) }
        .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    var pieces: [String] = []
    var spans: [[String: Any]] = []
    var previousEnd: Int? = nil
    var previousAtom: IntentAtom? = nil
    let atomByID = Dictionary(uniqueKeysWithValues: atoms.map { ($0.atomID, $0) })

    func peerGroup(_ atom: IntentAtom?) -> Int? {
        guard let atom, atom.kind.hasPrefix("peer-") else { return nil }
        if atom.kind == "peer-speaker-prefix" { return atom.atomID }
        for dependency in atom.dependencies {
            if atomByID[dependency]?.kind == "peer-speaker-prefix" {
                return dependency
            }
        }
        return nil
    }

    for atom in chosen {
        if let prev = previousEnd, atom.start > prev {
            let gapScalars = Array(scalars[prev ..< atom.start])
            let gapIsWhitespace = gapScalars.allSatisfy { isPythonWhitespace($0) }
            let previousPeerGroup = peerGroup(previousAtom)
            let samePeerTurn = previousPeerGroup != nil && previousPeerGroup == peerGroup(atom)
            // v23 uses one space for an omitted non-whitespace gap inside the
            // same named-peer turn. Every v22 gap remains byte-identical.
            if gapIsWhitespace {
                pieces.append(scalarsToString(gapScalars))
            } else if samePeerTurn {
                pieces.append(" ")
            } else {
                pieces.append("\n\n")
            }
        }
        // Assertion mirrors Python: atom.text == source[atom.start:atom.end].
        // We trust the atoms are consistent; this is a non-crashing debug check.
        // (No assert in release builds per Swift conventions.)
        pieces.append(atom.text)
        // Speaker is null in JSON when nil. NSNull() bridges correctly via JSONSerialization.
        let speakerValue: Any = atom.speaker.map { $0 as Any } ?? NSNull()
        spans.append([
            "atom_id": atom.atomID,
            "start": atom.start,
            "end": atom.end,
            "kind": atom.kind,
            "speaker": speakerValue,
            "dependencies": atom.dependencies,
            "hard_required": atom.hardRequired || hardIDs.contains(atom.atomID),
        ])
        previousEnd = atom.end
        previousAtom = atom
    }
    return (pieces.joined(), spans)
}

// MARK: - renderPeerAttributedProse

/// Renders selected named-peer turns as one attributed prose stream.
///
/// Mirrors v23.2 `render_peer_attributed_prose` without a regex engine. The
/// selected evidence and its source spans do not change; only presentation
/// topology changes from `Name: body` lines to `Name said: “body”` clauses.
func renderPeerAttributedProse(_ text: String) -> String {
    let scalars = Array(text.unicodeScalars)
    var lines: [[Unicode.Scalar]] = []
    var lineStart = 0
    var index = 0

    func isPythonLineBoundary(_ value: UInt32) -> Bool {
        value == 0x0A || value == 0x0B || value == 0x0C || value == 0x0D
            || (value >= 0x1C && value <= 0x1E) || value == 0x85
            || value == 0x2028 || value == 0x2029
    }

    while index < scalars.count {
        guard isPythonLineBoundary(scalars[index].value) else {
            index += 1
            continue
        }
        lines.append(Array(scalars[lineStart ..< index]))
        if scalars[index].value == 0x0D,
           index + 1 < scalars.count,
           scalars[index + 1].value == 0x0A {
            index += 2
        } else {
            index += 1
        }
        lineStart = index
    }
    if lineStart < scalars.count {
        lines.append(Array(scalars[lineStart...]))
    }

    return lines.compactMap { rawLine -> String? in
        let line = pyStrip(rawLine)
        guard !line.isEmpty else { return nil }

        // Python pattern: ^([A-Za-z][A-Za-z ._-]{0,31}):\s*(.*)$
        var cursor = 0
        guard atlSelectionIsAlpha(line[cursor].value) else {
            return scalarsToString(line)
        }
        cursor += 1
        var tailCount = 0
        while cursor < line.count && tailCount < 31 {
            let value = line[cursor].value
            let allowed = atlSelectionIsAlpha(value) || value == 0x20
                || value == 0x2E || value == 0x5F || value == 0x2D
            if !allowed { break }
            cursor += 1
            tailCount += 1
        }
        guard cursor < line.count, line[cursor].value == 0x3A else {
            return scalarsToString(line)
        }

        let speaker = scalarsToString(Array(line[0 ..< cursor]))
        cursor += 1
        while cursor < line.count && isPythonWhitespace(line[cursor]) { cursor += 1 }
        let body = scalarsToString(Array(line[cursor...]))
        return "\(speaker) said: “\(body)”"
    }.joined(separator: " ")
}

// MARK: - portableSpanOffsets

/// Attaches explicit UTF-8 byte offsets to code-point-offset spans.
///
/// Mirrors Python's ``_portable_span_offsets``.
/// Accumulates UTF-8 byte counts incrementally across sorted code-point positions
/// to avoid redundant prefix scans.
public func portableSpanOffsets(
    scalars: [Unicode.Scalar],
    spans: [[String: Any]]
) -> [[String: Any]] {
    // Collect all unique code-point positions referenced in the spans.
    var posSet = Set<Int>()
    for span in spans {
        if let s = span["start"] as? Int { posSet.insert(s) }
        if let e = span["end"] as? Int { posSet.insert(e) }
    }
    let sortedPositions = posSet.sorted()

    // Walk from position to position, accumulating UTF-8 bytes.
    // Mirror Python: byte_offset += len(source[previous:position].encode("utf-8"))
    var utf8Offsets: [Int: Int] = [:]
    var previous = 0
    var byteOffset = 0
    for position in sortedPositions {
        // Add UTF-8 bytes from previous code-point position to this one.
        for i in previous ..< position {
            // Each Unicode.Scalar encodes to 1–4 UTF-8 bytes.
            byteOffset += scalars[i].utf8.count
        }
        utf8Offsets[position] = byteOffset
        previous = position
    }

    // Annotate each span with start_utf8_byte and end_utf8_byte.
    return spans.map { span in
        var item = span
        let s = (item["start"] as? Int) ?? 0
        let e = (item["end"] as? Int) ?? 0
        item["start_utf8_byte"] = utf8Offsets[s] ?? 0
        item["end_utf8_byte"] = utf8Offsets[e] ?? 0
        return item
    }
}

// MARK: - sourceOccurrences

/// Returns code-point spans of case-insensitive whole-"word" matches of `value`
/// in `scalars`.
///
/// Mirrors Python's ``_source_occurrences``:
///   ``re.finditer(rf"(?<![\w]){re.escape(value)}(?![\w])", source, re.IGNORECASE)``
///
/// `[\w]` in Python regex is `[A-Za-z0-9_]`.
/// The function returns `[(start, end)]` code-point spans (end is exclusive).
/// Python returns Match objects; callers only need .start(), .end(), and the
/// matched text's first character.
public func sourceOccurrences(
    scalars: [Unicode.Scalar],
    value: String
) -> [(start: Int, end: Int)] {
    let valSc = Array(value.unicodeScalars)
    let valLen = valSc.count
    let n = scalars.count
    // SECURITY: guard against closed-range trap (0 ... (n - valLen)) when valLen > n,
    // and skip empty values. Mirrors the Rust guard at distiller.rs:125 exactly:
    // `if vn == 0 || vn > n { return Vec::new(); }`
    guard valLen > 0, valLen <= n else { return [] }
    var results: [(Int, Int)] = []

    // Case-insensitive comparison helper: compare two Unicode scalars ignoring ASCII case.
    // Python re.IGNORECASE for ASCII is simple toLower comparison.
    // For non-ASCII, we use Swift's lowercased() comparison (acceptable approximation;
    // trailer values are ASCII-only in practice).
    func scalarsEqual(_ a: Unicode.Scalar, _ b: Unicode.Scalar) -> Bool {
        let av = a.value, bv = b.value
        // Fast ASCII path.
        if av < 128 && bv < 128 {
            let aL = av >= 0x41 && av <= 0x5A ? av + 0x20 : av
            let bL = bv >= 0x41 && bv <= 0x5A ? bv + 0x20 : bv
            return aL == bL
        }
        // Slow path for non-ASCII.
        return String(a).lowercased() == String(b).lowercased()
    }

    func isPythonWordChar(_ sc: Unicode.Scalar) -> Bool {
        let v = sc.value
        return (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
            || (v >= 0x30 && v <= 0x39) || v == 0x5F
    }

    for i in 0 ... (n - valLen) {
        // Check negative lookbehind: previous char must not be \w.
        if i > 0 && isPythonWordChar(scalars[i - 1]) { continue }
        // Match value case-insensitively.
        var matched = true
        for k in 0 ..< valLen {
            if !scalarsEqual(scalars[i + k], valSc[k]) { matched = false; break }
        }
        guard matched else { continue }
        let endIdx = i + valLen
        // Check negative lookahead: next char must not be \w.
        if endIdx < n && isPythonWordChar(scalars[endIdx]) { continue }
        results.append((i, endIdx))
    }
    return results
}

// MARK: - sentenceInitial

/// Returns `true` when position `start` in `scalars` is sentence-initial.
///
/// "Sentence-initial" means there is no preceding non-whitespace non-punctuation
/// character on the same text segment (before the position).
///
/// Mirrors Python's ``_sentence_initial``.
public func sentenceInitial(scalars: [Unicode.Scalar], start: Int) -> Bool {
    // Mirror Python: cursor scans backward from start-1.
    // Python: source[cursor] in "-*>•([{\"'" → skip (treated as punctuation, not content).
    // Python: source[cursor] == "\n" → True (line start is sentence initial).
    // Python: source[cursor].isspace() → skip.
    let skipPunct: Set<UInt32> = [
        0x2D,  // -
        0x2A,  // *
        0x3E,  // >
        0x2022, // •
        0x28,  // (
        0x5B,  // [
        0x7B,  // {
        0x22,  // "
        0x27,  // '
    ]
    var cursor = start - 1
    while cursor >= 0 {
        let v = scalars[cursor].value
        if v == 0x0A { return true }  // newline
        // Python: source[cursor].isspace() — isPythonWhitespace covers \s.
        if isPythonWhitespace(scalars[cursor]) { cursor -= 1; continue }
        if skipPunct.contains(v) { cursor -= 1; continue }
        break
    }
    // cursor < 0 means start of text (sentence initial).
    // cursor >= 0: check if the char is a sentence-ending punctuation.
    if cursor < 0 { return true }
    let v = scalars[cursor].value
    return v == 0x2E || v == 0x21 || v == 0x3F || v == 0x0A
}

// MARK: - projectIntentTrailer

/// Projects only source-anchored, type-context-safe trailer fields.
///
/// Mirrors Python's ``project_intent_trailer``.
/// Returns `(projectedTrailer, projection)` where projection is the metadata dict.
/// `scalars` is the projection source (may differ from original when derived-answer
/// spans have been blanked for document-exchange mode).
public func projectIntentTrailer(
    scalars: [Unicode.Scalar],
    trailer: String
) -> (projected: String, projection: [String: Any]) {
    var accepted: [[String: Any]] = []
    var rejected: [[String: Any]] = []

    guard !trailer.isEmpty else {
        return ("", ["accepted": accepted, "rejected": rejected])
    }

    // Mirror Python: re.fullmatch(r"\(\*\[\s*(.*?)\s*\]\*\)", trailer, re.DOTALL)
    let trailerSc = Array(trailer.unicodeScalars)
    guard let innerRange = matchTrailerGrammar(trailerSc) else {
        return ("", ["accepted": accepted, "rejected": [
            ["raw": trailer, "reason": "invalid-trailer-grammar"]
        ]])
    }

    let innerStr = scalarsToString(Array(trailerSc[innerRange])).trimmingCharacters(in: .whitespaces)

    // Mirror Python: re.split(r",\s*(?=[A-Za-z][A-Za-z0-9_-]*\s*:)", inner)
    // Split on commas followed by a field-label pattern.
    let rawFields = splitTrailerFields(innerStr)

    for raw in rawFields {
        let field = raw.trimmingCharacters(in: .whitespaces)
        guard !field.isEmpty else { continue }
        guard let colonIdx = field.firstIndex(of: ":") else {
            rejected.append(["raw": field, "reason": "invalid-field"])
            continue
        }
        let label = field[field.startIndex ..< colonIdx]
            .trimmingCharacters(in: .whitespaces).lowercased()
        let value = field[field.index(after: colonIdx)...]
            .trimmingCharacters(in: .whitespaces)

        let occurrences = sourceOccurrences(scalars: scalars, value: value)
        var reason: String? = nil

        if opaqueLabels.contains(label) {
            reason = "opaque-taxonomy"
        } else if !supportedFieldLabels.contains(label) {
            reason = "unsupported-field-type"
        } else if occurrences.isEmpty {
            reason = "not-source-anchored"
        } else if label == "entity" {
            reason = checkEntityContext(scalars: scalars, value: value,
                                        occurrences: occurrences)
        } else if label == "place" || label == "country" {
            reason = checkLocativeContext(scalars: scalars, value: value,
                                          label: label, occurrences: occurrences)
        } else if label == "date" {
            // Mirror Python: not DATE_RE.fullmatch(value) → "unsafe-date-context"
            if !dateREFullmatch(value) { reason = "unsafe-date-context" }
        } else if label == "quantity" {
            // Mirror Python: not QUANTITY_VALUE_RE.fullmatch(value)
            if !quantityValueREFullmatch(value) { reason = "unsafe-quantity-context" }
        }

        var item: [String: Any] = ["field": label, "value": value, "raw": field]
        if let r = reason {
            item["reason"] = r
            rejected.append(item)
        } else {
            accepted.append(item)
        }
    }

    // Build projected trailer string.
    var projected = ""
    if !accepted.isEmpty {
        let body = accepted.map { item -> String in
            let f = item["field"] as? String ?? ""
            let v = item["value"] as? String ?? ""
            return "\(f): \(v)"
        }.joined(separator: ", ")
        projected = "(*[ \(body) ]*)"
    }

    return (projected, ["accepted": accepted, "rejected": rejected])
}

// MARK: - Trailer grammar helpers

/// Matches the trailer grammar `\(\*\[\s*(.*?)\s*\]\*\)` and returns the
/// range of the inner capture group (in scalars-index space).
///
/// Mirror: Python ``re.fullmatch(r"\(\*\[\s*(.*?)\s*\]\*\)", trailer, re.DOTALL)``
private func matchTrailerGrammar(_ sc: [Unicode.Scalar]) -> Range<Int>? {
    let n = sc.count
    // Must start with (*[
    guard n >= 6 else { return nil }
    guard sc[0].value == 0x28, sc[1].value == 0x2A, sc[2].value == 0x5B else { return nil }
    // Must end with ]*)
    guard sc[n - 3].value == 0x5D, sc[n - 2].value == 0x2A, sc[n - 1].value == 0x29 else { return nil }
    // Inner is sc[3..<(n-3)], then strip leading/trailing whitespace.
    return 3 ..< (n - 3)
}

/// Splits the trailer inner string on commas that are followed by a field label.
///
/// Mirror: Python ``re.split(r",\s*(?=[A-Za-z][A-Za-z0-9_-]*\s*:)", s)``
private func splitTrailerFields(_ s: String) -> [String] {
    let sc = Array(s.unicodeScalars)
    let n = sc.count
    var parts: [String] = []
    var segStart = 0

    var i = 0
    while i < n {
        if sc[i].value == 0x2C {  // comma
            // Look ahead for \s*[A-Za-z][A-Za-z0-9_-]*\s*:
            var j = i + 1
            while j < n && isPythonWhitespace(sc[j]) { j += 1 }
            if isFieldLabelStart(sc, at: j, limit: n) {
                parts.append(scalarsToString(Array(sc[segStart ..< i])))
                segStart = i + 1
            }
        }
        i += 1
    }
    parts.append(scalarsToString(Array(sc[segStart...])))
    return parts
}

/// Returns true when `sc[at...]` starts a trailer field label: `[A-Za-z][A-Za-z0-9_-]*\s*:`.
private func isFieldLabelStart(_ sc: [Unicode.Scalar], at start: Int, limit: Int) -> Bool {
    guard start < limit else { return false }
    let v0 = sc[start].value
    guard (v0 >= 0x41 && v0 <= 0x5A) || (v0 >= 0x61 && v0 <= 0x7A) else { return false }
    var i = start + 1
    while i < limit {
        let v = sc[i].value
        if (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
            || (v >= 0x30 && v <= 0x39) || v == 0x5F || v == 0x2D {
            i += 1
        } else { break }
    }
    while i < limit && isPythonWhitespace(sc[i]) { i += 1 }
    return i < limit && sc[i].value == 0x3A
}

// MARK: - Entity / place / date / quantity context checks

/// Mirrors Python's entity-context validation in ``project_intent_trailer``.
private func checkEntityContext(
    scalars: [Unicode.Scalar],
    value: String,
    occurrences: [(start: Int, end: Int)]
) -> String? {
    let valueLower = value.lowercased()
    if entityNonNameValues.contains(valueLower) { return "unsafe-entity-context" }

    // Mirror Python: value_terms[0] in ENTITY_NON_NAME_PREFIXES
    let valueTerms = normalizedTerms(value)
    if let firstTerm = valueTerms.first, entityNonNamePrefixes.contains(firstTerm) {
        return "unsafe-entity-context"
    }

    // Mirror Python: capitalized_any = any(source[m.start():m.end()][:1].isupper() for m in occurrences)
    let capitalized_any = occurrences.contains { occ in
        occ.start < scalars.count && pyIsUpper(scalars[occ.start])
    }
    // Mirror Python: capitalized = any(... and not _sentence_initial(source, m.start()) ...)
    let capitalized = occurrences.contains { occ in
        occ.start < scalars.count && pyIsUpper(scalars[occ.start])
        && !sentenceInitial(scalars: scalars, start: occ.start)
    }

    // Mirror Python: cue = re.search(rf"\b{ENTITY_CUE}\s+(?:the\s+)?{re.escape(value)}\b", ...)
    let cue = hasEntityCue(scalars: scalars, value: value)
    // Mirror Python: subject_cue = capitalized_any and re.search(...)
    let subjectCue = capitalized_any && hasEntitySubjectCue(scalars: scalars, value: value)

    if !capitalized && !cue && !subjectCue {
        return "unsafe-entity-context"
    }
    return nil
}

/// Mirrors Python's place/country context validation.
private func checkLocativeContext(
    scalars: [Unicode.Scalar],
    value: String,
    label: String,
    occurrences: [(start: Int, end: Int)]
) -> String? {
    // Mirror Python: cue = re.search(rf"\b{LOCATIVE_CUE}\s+(?:the\s+)?{re.escape(value)}\b", ...)
    let cue = hasLocativeCue(scalars: scalars, value: value)
    // Mirror Python: explicit = re.search(rf"\b{label}\s*(?:is|:)?\s*{re.escape(value)}\b", ...)
    let explicit = hasExplicitLabel(scalars: scalars, label: label, value: value)
    if !cue && !explicit { return "unsafe-locative-context" }
    return nil
}

// MARK: - Cue-search helpers (hand-written scanners replacing regex)

/// Checks for ENTITY_CUE word followed by optional "the " then the entity value.
/// Mirror: `re.search(rf"\b{ENTITY_CUE}\s+(?:the\s+)?{re.escape(value)}\b", source, re.IGNORECASE)`
private func hasEntityCue(scalars: [Unicode.Scalar], value: String) -> Bool {
    for cue in entityCueWords {
        if searchCuePrecededByWordBoundary(scalars: scalars, cue: cue, value: value, optionalThe: true) {
            return true
        }
    }
    return false
}

/// Checks for entity value followed by ENTITY_SUBJECT_CUE word.
/// Mirror: `re.search(rf"\b{re.escape(value)}\s+{ENTITY_SUBJECT_CUE}\b", source, re.IGNORECASE)`
private func hasEntitySubjectCue(scalars: [Unicode.Scalar], value: String) -> Bool {
    for cue in entitySubjectCueWords {
        if searchValueFollowedByCue(scalars: scalars, value: value, cue: cue) {
            return true
        }
    }
    return false
}

/// Checks for LOCATIVE_CUE word followed by optional "the " then the place value.
private func hasLocativeCue(scalars: [Unicode.Scalar], value: String) -> Bool {
    for cue in locativeCueWords {
        if searchCuePrecededByWordBoundary(scalars: scalars, cue: cue, value: value, optionalThe: true) {
            return true
        }
    }
    return false
}

/// Checks for `\blabel\s*(?:is|:)?\s*value\b`.
private func hasExplicitLabel(scalars: [Unicode.Scalar], label: String, value: String) -> Bool {
    let n = scalars.count
    let labelSc = Array(label.unicodeScalars)
    let valueSc = Array(value.unicodeScalars)
    let labelLen = labelSc.count
    let valueLen = valueSc.count

    for i in 0 ..< n {
        // Word boundary before label.
        if i > 0 && isPythonWordChar(scalars[i - 1]) { continue }
        // Match label case-insensitively.
        guard i + labelLen <= n else { continue }
        var matched = true
        for k in 0 ..< labelLen {
            if !scEqualCI(scalars[i + k], labelSc[k]) { matched = false; break }
        }
        guard matched else { continue }
        var j = i + labelLen
        // \s*
        while j < n && isPythonWhitespace(scalars[j]) { j += 1 }
        // (?:is|:)?
        if j < n {
            let jv = scalars[j].value, j1v = j + 1 < n ? scalars[j+1].value : 0
            let isWord = (jv == 0x69 || jv == 0x49) && (j1v == 0x73 || j1v == 0x53)
            if j + 2 <= n && isWord {
                // "is" or "Is" — case-insensitive
                j += 2
            } else if scalars[j].value == 0x3A {
                j += 1
            }
        }
        // \s*
        while j < n && isPythonWhitespace(scalars[j]) { j += 1 }
        // Match value case-insensitively.
        guard j + valueLen <= n else { continue }
        var vmatch = true
        for k in 0 ..< valueLen {
            if !scEqualCI(scalars[j + k], valueSc[k]) { vmatch = false; break }
        }
        guard vmatch else { continue }
        let endIdx = j + valueLen
        // Word boundary after value.
        if endIdx < n && isPythonWordChar(scalars[endIdx]) { continue }
        return true
    }
    return false
}

/// Searches for `\bcue\s+(?:the\s+)?value\b` (case-insensitive).
private func searchCuePrecededByWordBoundary(
    scalars: [Unicode.Scalar],
    cue: String,
    value: String,
    optionalThe: Bool
) -> Bool {
    let n = scalars.count
    let cueSc = Array(cue.unicodeScalars)
    let valueSc = Array(value.unicodeScalars)
    let cueLen = cueSc.count
    let valueLen = valueSc.count

    for i in 0 ..< n {
        if i > 0 && isPythonWordChar(scalars[i - 1]) { continue }
        guard i + cueLen <= n else { continue }
        var cMatch = true
        for k in 0 ..< cueLen {
            if !scEqualCI(scalars[i + k], cueSc[k]) { cMatch = false; break }
        }
        guard cMatch else { continue }
        // Word boundary after cue.
        let afterCue = i + cueLen
        if afterCue < n && isPythonWordChar(scalars[afterCue]) { continue }
        var j = afterCue
        // \s+
        guard j < n && isPythonWhitespace(scalars[j]) else { continue }
        while j < n && isPythonWhitespace(scalars[j]) { j += 1 }
        // (?:the\s+)?
        if optionalThe && j + 3 <= n
            && (scalars[j].value == 0x74 || scalars[j].value == 0x54)
            && (scalars[j+1].value == 0x68 || scalars[j+1].value == 0x48)
            && (scalars[j+2].value == 0x65 || scalars[j+2].value == 0x45)
            && (j + 3 >= n || isPythonWhitespace(scalars[j+3])) {
            j += 3
            while j < n && isPythonWhitespace(scalars[j]) { j += 1 }
        }
        // Match value.
        guard j + valueLen <= n else { continue }
        var vMatch = true
        for k in 0 ..< valueLen {
            if !scEqualCI(scalars[j + k], valueSc[k]) { vMatch = false; break }
        }
        guard vMatch else { continue }
        let endIdx = j + valueLen
        if endIdx < n && isPythonWordChar(scalars[endIdx]) { continue }
        return true
    }
    return false
}

/// Searches for `\bvalue\s+cue\b` (case-insensitive).
private func searchValueFollowedByCue(
    scalars: [Unicode.Scalar],
    value: String,
    cue: String
) -> Bool {
    let n = scalars.count
    let valueSc = Array(value.unicodeScalars)
    let cueSc = Array(cue.unicodeScalars)
    let valueLen = valueSc.count
    let cueLen = cueSc.count

    for i in 0 ..< n {
        if i > 0 && isPythonWordChar(scalars[i - 1]) { continue }
        guard i + valueLen <= n else { continue }
        var vMatch = true
        for k in 0 ..< valueLen {
            if !scEqualCI(scalars[i + k], valueSc[k]) { vMatch = false; break }
        }
        guard vMatch else { continue }
        let afterValue = i + valueLen
        if afterValue < n && isPythonWordChar(scalars[afterValue]) { continue }
        var j = afterValue
        // \s+
        guard j < n && isPythonWhitespace(scalars[j]) else { continue }
        while j < n && isPythonWhitespace(scalars[j]) { j += 1 }
        // Match cue.
        guard j + cueLen <= n else { continue }
        var cMatch = true
        for k in 0 ..< cueLen {
            if !scEqualCI(scalars[j + k], cueSc[k]) { cMatch = false; break }
        }
        guard cMatch else { continue }
        let endIdx = j + cueLen
        if endIdx < n && isPythonWordChar(scalars[endIdx]) { continue }
        return true
    }
    return false
}

// MARK: - DATE_RE fullmatch / QUANTITY_VALUE_RE fullmatch

/// Mirror Python's `DATE_RE.fullmatch(value)` for trailer date validation.
///
/// Pattern: \b(?:\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2})?)?|\d{1,2}[/-]\d{1,2}[/-]\d{2,4}|\d{4})\b
/// For fullmatch we require the entire string to match.
private func dateREFullmatch(_ value: String) -> Bool {
    let sc = Array(value.unicodeScalars)
    let n = sc.count
    guard n > 0 else { return false }

    func isDigit(_ i: Int) -> Bool { i < n && sc[i].value >= 0x30 && sc[i].value <= 0x39 }

    let i = 0
    // Try \d{4}-\d{2}-\d{2}(T...)?
    var j = i
    var cnt = 0
    while j < n && isDigit(j) { j += 1; cnt += 1 }
    if cnt == 4 && j < n && sc[j].value == 0x2D {
        j += 1; cnt = 0
        while j < n && isDigit(j) { j += 1; cnt += 1 }
        if cnt == 2 && j < n && sc[j].value == 0x2D {
            j += 1; cnt = 0
            while j < n && isDigit(j) { j += 1; cnt += 1 }
            if cnt == 2 {
                // Optional T time
                if j < n && sc[j].value == 0x54 {
                    j += 1; cnt = 0
                    while j < n && isDigit(j) { j += 1; cnt += 1 }
                    if cnt == 2 && j < n && sc[j].value == 0x3A {
                        j += 1; cnt = 0
                        while j < n && isDigit(j) { j += 1; cnt += 1 }
                        if cnt == 2 {
                            if j < n && sc[j].value == 0x3A {
                                j += 1; cnt = 0
                                while j < n && isDigit(j) { j += 1; cnt += 1 }
                            }
                        } else { return false }
                    } else { return false }
                }
                if j == n { return true }
            }
        }
    }

    // Try \d{1,2}[/-]\d{1,2}[/-]\d{2,4}
    j = i; cnt = 0
    while j < n && isDigit(j) && cnt < 2 { j += 1; cnt += 1 }
    if cnt >= 1 && j < n && (sc[j].value == 0x2F || sc[j].value == 0x2D) {
        j += 1; cnt = 0
        while j < n && isDigit(j) && cnt < 2 { j += 1; cnt += 1 }
        if cnt >= 1 && j < n && (sc[j].value == 0x2F || sc[j].value == 0x2D) {
            j += 1; cnt = 0
            while j < n && isDigit(j) && cnt < 4 { j += 1; cnt += 1 }
            if cnt >= 2 && cnt <= 4 && j == n { return true }
        }
    }

    // Try \d{4} (exactly 4 digits)
    j = i; cnt = 0
    while j < n && isDigit(j) { j += 1; cnt += 1 }
    if cnt == 4 && j == n { return true }

    return false
}

/// Mirror Python's `QUANTITY_VALUE_RE.fullmatch(value)`.
///
/// Pattern: `^[€£$]?\d+(?:[.,]\d+)?(?:\s+[A-Za-z%][A-Za-z0-9%._/-]*){0,3}$`
private func quantityValueREFullmatch(_ value: String) -> Bool {
    let sc = Array(value.unicodeScalars)
    let n = sc.count
    guard n > 0 else { return false }
    var i = 0

    // Optional currency symbol
    if i < n && (sc[i].value == 0x20AC || sc[i].value == 0xA3 || sc[i].value == 0x24) { i += 1 }
    // \d+
    guard i < n && sc[i].value >= 0x30 && sc[i].value <= 0x39 else { return false }
    while i < n && sc[i].value >= 0x30 && sc[i].value <= 0x39 { i += 1 }
    // (?:[.,]\d+)?
    if i < n && (sc[i].value == 0x2C || sc[i].value == 0x2E) {
        let saved = i; i += 1
        if i < n && sc[i].value >= 0x30 && sc[i].value <= 0x39 {
            while i < n && sc[i].value >= 0x30 && sc[i].value <= 0x39 { i += 1 }
        } else { i = saved }
    }
    // (?:\s+[A-Za-z%][A-Za-z0-9%._/-]*){0,3}
    var unitCount = 0
    while unitCount < 3 && i < n {
        guard isPythonWhitespace(sc[i]) else { break }
        let savedI = i
        while i < n && isPythonWhitespace(sc[i]) { i += 1 }
        // [A-Za-z%]
        guard i < n else { i = savedI; break }
        let v = sc[i].value
        guard (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) || v == 0x25 else {
            i = savedI; break
        }
        i += 1
        // [A-Za-z0-9%._/-]*
        while i < n {
            let vv = sc[i].value
            if (vv >= 0x41 && vv <= 0x5A) || (vv >= 0x61 && vv <= 0x7A)
                || (vv >= 0x30 && vv <= 0x39) || vv == 0x25 || vv == 0x2E
                || vv == 0x5F || vv == 0x2F || vv == 0x2D {
                i += 1
            } else { break }
        }
        unitCount += 1
    }
    return i == n
}

// MARK: - Helper: case-insensitive scalar comparison

/// Case-insensitive comparison for ASCII (and fallback non-ASCII).
private func scEqualCI(_ a: Unicode.Scalar, _ b: Unicode.Scalar) -> Bool {
    let av = a.value, bv = b.value
    if av < 128 && bv < 128 {
        let aL = av >= 0x41 && av <= 0x5A ? av + 0x20 : av
        let bL = bv >= 0x41 && bv <= 0x5A ? bv + 0x20 : bv
        return aL == bL
    }
    return String(a).lowercased() == String(b).lowercased()
}

// MARK: - scalarsToString (local copy to avoid visibility issues)
// isPythonWordChar is public in PythonText.swift and used directly from there.

/// Converts an array of Unicode.Scalar to String.
private func scalarsToString(_ scalars: [Unicode.Scalar]) -> String {
    var s = ""
    s.unicodeScalars.append(contentsOf: scalars)
    return s
}

// MARK: - intentSpan

/// Deterministic work ceilings, shared in value with the Rust selector. Above
/// these limits compression is declined: the complete source is retained.
private let selectionMaxSourceBytes = 32768
private let selectionMaxAtoms = 256
private let selectionMaxWork = 100_000

private func selectionBudgetFallback(_ source: String, reason: String) -> IntentSpanResult {
    IntentSpanResult(core: source, selectedSpans: [[
        "start": 0, "end": source.unicodeScalars.count,
        "start_utf8_byte": 0, "end_utf8_byte": source.utf8.count,
        "kind": "complete-source-budget-fallback",
    ]], selectionDetails: [
        "mode": "resource-budget", "exact_source_spans": true,
        "unsupported_shapes": [reason], "compression_skipped": true,
    ], projectedTrailer: "")
}

/// Selects complete exact source atoms with deterministic dependencies.
///
/// Mirrors Python's ``intent_span`` (without the _combine call and without
/// exposing trailer_projection in the result — that is Part 5 scope).
///
/// Returns an ``IntentSpanResult`` with:
///   - `core`: concatenated selected atom text
///   - `selectedSpans`: per-atom metadata with UTF-8 byte offsets
///   - `selectionDetails`: full metadata except `trailer_projection`
public func intentSpan(
    _ source: String,
    trailer: String,
    peerDialogue: Bool = false,
    bounded: Bool = false
) -> IntentSpanResult {
    if bounded && source.utf8.prefix(selectionMaxSourceBytes + 1).count > selectionMaxSourceBytes {
        return selectionBudgetFallback(source, reason: "source-byte-budget")
    }
    let scalars = Array(source.unicodeScalars)

    // --- atoms, hard, coverage, unsupported, mode_details ---
    let atomsResult = intentAtoms(scalars, peerDialogue: peerDialogue)
    let atoms = atomsResult.atoms
    if bounded && atoms.count > selectionMaxAtoms {
        return selectionBudgetFallback(source, reason: "atom-budget")
    }
    let hard = atomsResult.hardIDs
    let coverage = atomsResult.coverageIDs
    let unsupported = atomsResult.unsupported
    let mode = atomsResult.mode

    // --- derived_answer_omitted: blank the generated-transform span ---
    // Mirror Python: if omitted, replace that source region with spaces so
    // project_intent_trailer cannot anchor trailer fields into the transform.
    var projectionScalars = scalars
    var excludedProjectionSpans: [[String: Any]] = []
    if mode == "document-exchange",
       let omitted = atomsResult.modeExtras["derived_answer_omitted"] as? [String: Any],
       let omStart = omitted["start"] as? Int,
       let omEnd = omitted["end"] as? Int,
       omStart >= 0, omEnd >= omStart, omEnd <= scalars.count {
        // Replace [omStart, omEnd) with spaces (preserves code-point offsets).
        for i in omStart ..< omEnd {
            projectionScalars[i] = Unicode.Scalar(0x20)!  // space
        }
        excludedProjectionSpans.append([
            "start": omStart,
            "end": omEnd,
            "reason": "generated-transform-not-source-evidence",
        ])
    }

    // --- project_intent_trailer (needed for correct budget math) ---
    let projectedTrailerResult = projectIntentTrailer(
        scalars: projectionScalars,
        trailer: trailer
    )
    let projectedTrailer = projectedTrailerResult.projected
    var projection = projectedTrailerResult.projection
    projection["excluded_source_spans"] = excludedProjectionSpans

    // --- initial selection: dependency closure of hard ∪ coverage ---
    let atomByID = Dictionary(uniqueKeysWithValues: atoms.map { ($0.atomID, $0) })
    var selected: Set<Int>
    if atoms.isEmpty {
        selected = []
    } else {
        selected = dependencyClosure(atomByID: atomByID, initial: hard.union(coverage))
    }

    // --- budget ---
    let budgetPercent: Int
    if mode == "document-exchange"
        && !(atomsResult.modeExtras["protected_document_structure"] as? Bool ?? false) {
        budgetPercent = 35
    } else {
        budgetPercent = 55
    }
    let srcBytes = source.utf8.count
    let budget = max(
        512,
        srcBytes * budgetPercent / 100 - projectedTrailer.utf8.count
    )

    // --- preserve_all_short ---
    let preserveAllShort = srcBytes <= 512 || (mode == "document" && srcBytes <= 2048)
    if preserveAllShort {
        selected = atoms.isEmpty ? [] : dependencyClosure(
            atomByID: atomByID,
            initial: Set(atomByID.keys)
        )
    }

    // --- pre-compute per-atom caches ---
    var termsByID: [Int: Set<String>] = [:]
    var relevanceByID: [Int: Int] = [:]
    var normalizedByID: [Int: String] = [:]
    for atom in atoms {
        termsByID[atom.atomID] = Set(normalizedTerms(atom.text))
        relevanceByID[atom.atomID] = intentRelevancePublic(atom)
        normalizedByID[atom.atomID] = normalizedAtomTextPublic(atom)
    }

    // --- greedy budget loop ---
    // Mirror Python: remaining excludes headings and already-selected atoms.
    var remaining: [IntentAtom] = atoms.filter {
        !selected.contains($0.atomID)
        && $0.kind != "heading" && $0.kind != "answer-heading"
        && $0.kind != "peer-speaker-prefix"
    }
    var budgetRejected: [[String: Any]] = []

    var workRemaining = selectionMaxWork
    while !remaining.isEmpty {
        // Charge the entire scan before starting it, independent of Set order.
        // Include closure/render scans as well as candidate/selected comparisons.
        let cost = remaining.count * (selected.count + 1) + atoms.count * 2
        if bounded && cost > workRemaining {
            return selectionBudgetFallback(source, reason: "selector-work-budget")
        }
        if bounded { workRemaining -= cost }
        // Compute selected_terms and selected_normalized for this iteration.
        var selectedTerms = Set<String>()
        for id in selected { selectedTerms.formUnion(termsByID[id] ?? []) }
        let selectedNormalized = Set(selected.compactMap { normalizedByID[$0] })

        // Rank remaining atoms by (utility, relevance, -start).
        // Mirror Python: utility = relevance*1000 + novelty*120 - max_overlap*300
        var best: IntentAtom? = nil
        var bestUtility = Int.min
        var bestRelevance = Int.min
        var bestNegStart = Int.min

        for atom in remaining {
            let terms = termsByID[atom.atomID] ?? []
            let novelty = terms.subtracting(selectedTerms).count
            let maxOverlap = selected.isEmpty ? 0 : selected.map {
                overlapPermille(terms, termsByID[$0] ?? [])
            }.max() ?? 0
            let relevance = relevanceByID[atom.atomID] ?? 0
            let utility = relevance * 1000 + novelty * 120 - maxOverlap * 300
            let negStart = -atom.start

            if utility > bestUtility
                || (utility == bestUtility && relevance > bestRelevance)
                || (utility == bestUtility && relevance == bestRelevance && negStart > bestNegStart) {
                best = atom
                bestUtility = utility
                bestRelevance = relevance
                bestNegStart = negStart
            }
        }
        guard let atom = best else { break }
        remaining.removeAll { $0.atomID == atom.atomID }

        // Duplicate check.
        if let norm = normalizedByID[atom.atomID], selectedNormalized.contains(norm) {
            budgetRejected.append([
                "atom_id": atom.atomID,
                "kind": atom.kind,
                "bytes": atom.text.utf8.count,
                "reason": "exact-duplicate",
            ])
            continue
        }

        // Budget check: propose = dependency closure of selected ∪ {atom}.
        let proposed = dependencyClosure(
            atomByID: atomByID,
            initial: selected.union([atom.atomID])
        )
        if selectionBytes(scalars: scalars, atoms: atoms, selected: proposed) <= budget {
            selected = proposed
        } else {
            budgetRejected.append([
                "atom_id": atom.atomID,
                "kind": atom.kind,
                "bytes": atom.text.utf8.count,
                "reason": "complete-atom-does-not-fit",
            ])
        }
    }

    // --- render ---
    let (core, rawSpans) = renderExact(
        scalars: scalars, atoms: atoms, selected: selected, hardIDs: hard)
    let selectedBytes = core.utf8.count
    var finalUnsupported = unsupported
    if !atoms.isEmpty && core.trimmingCharacters(in: .whitespaces).isEmpty {
        finalUnsupported = Array(Set(finalUnsupported).union(["no-complete-atom-fits-budget"])).sorted()
    }

    // --- hard_closure: dependency closure of hard ∪ coverage ---
    let hardClosure = atoms.isEmpty ? Set<Int>()
        : dependencyClosure(atomByID: atomByID, initial: hard.union(coverage))

    // --- attach UTF-8 byte offsets to spans ---
    let portableSpans = portableSpanOffsets(scalars: scalars, spans: rawSpans)

    // --- assemble selection_details (without trailer_projection — Part 5 scope) ---
    // Mirror Python: details = {"selection": ..., "intent_span_version": ..., **mode_details, ...}
    var details: [String: Any] = [
        "selection": "intent-span-exact-source-atoms",
        "intent_span_version": intentSpanVersion,
    ]
    // Spread mode (always present as its own key).
    details["mode"] = mode
    // Spread mode-specific extras.
    for (k, v) in atomsResult.modeExtras { details[k] = v }
    // Core budget and selection metrics.
    details["core_budget_bytes"] = budget
    details["core_budget_percent"] = budgetPercent
    details["selected_core_bytes"] = selectedBytes
    details["budget_overflow"] = selectedBytes > budget
    details["empty_core"] = core.trimmingCharacters(in: .whitespaces).isEmpty
    details["preserve_all_short_document"] = preserveAllShort
    details["hard_required_atom_ids"] = hard.sorted()
    details["query_coverage_atom_ids"] = coverage.sorted()
    details["dependency_closed_atom_ids"] = hardClosure.sorted()
    details["budget_rejected_atoms"] = budgetRejected
    details["unsupported_shapes"] = finalUnsupported
    // trailer_projection is now included (Part 5). Mirrors Python:
    //   details["trailer_projection"] = projection
    details["trailer_projection"] = projection
    details["exact_source_spans"] = true

    return IntentSpanResult(
        core: core,
        selectedSpans: portableSpans,
        selectionDetails: details,
        projectedTrailer: projectedTrailer
    )
}

// MARK: - intentRelevancePublic / normalizedAtomTextPublic
// Internal-access wrappers to use the private functions from IntentAtomLayer.swift.
// Since Swift does not allow calling private functions across files, we replicate
// the logic here as internal functions. Both mirror Python exactly.

/// Mirrors Python's ``_intent_relevance``.
/// Scores an atom by its relevance for intent-span selection.
func intentRelevancePublic(_ atom: IntentAtom) -> Int {
    let sc = Array(atom.text.unicodeScalars)
    let terms = Set(normalizedTerms(atom.text))
    var score = terms.count * 10
    score += dateREFinditer(sc).count * 160
    score += numberREFinditer(sc).count * 100
    let actionStemsLocal: Set<String> = {
        var s = Set<String>()
        let words = ["agreed", "approved", "assigned", "build", "built", "cancel", "changed",
                     "choose", "decided", "deliver", "due", "failed", "fixed", "launch",
                     "must", "need", "planned", "prefer", "preferred", "prefers",
                     "preference", "favorite", "routine", "regularly", "usually", "required",
                     "ship", "shipped", "should", "started", "stop", "will", "won't"]
        for w in words { for t in normalizedTerms(w) { s.insert(t) } }
        return s
    }()
    score += terms.filter { actionStemsLocal.contains($0) }.count * 140
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

/// Mirrors Python's ``_normalized_atom_text``.
/// Returns the normalized (lowercase, whitespace-collapsed) text for deduplication.
func normalizedAtomTextPublic(_ atom: IntentAtom) -> String {
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
            text = String(text.unicodeScalars.dropFirst(markerMatches[0].end))
        }
    }
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
