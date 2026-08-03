// MeetingDecisionExtractor.swift
//
// DCP M6 — the controlled-decision grammar (DCP_M0_CONTRACT §9, locked).
// Line-anchored, one decision per line; anything the grammar cannot
// prove it understands resolves to Unknown WITH a reason — the extractor
// never guesses, because its output feeds the typed proving lane
// (ConflictProjection) where a wrong parse would manufacture evidence.
//
// Three accepted forms:
//   Decision: <entity>.<dimension> = <value>
//   Approved <dimension> for <entity>: <value>
//   Replaces decision <id>: <entity>.<dimension> = <value>
//
// Rejected to Unknown (F11/F12): pronoun entities, unregistered
// dimensions, values the rule's normalizer refuses (ambiguous dates,
// out-of-set tokens), quoted spans, hypothetical/reported-speech
// markers (if/would/might/reportedly/according to), multiple `=`.
//
// Pure: no clock, no I/O, no estate. The GLK wiring that files the
// extracted decisions as KGFacts lives in
// GeniusLocusKit/Brain/MeetingDecisionCapture.swift. Rust twin:
// rust/src/meeting_decision_extractor.rs.

import Foundation

/// Stable extractor identity stamped on everything this grammar files.
public let meetingDecisionExtractorID = "dcp-meeting-v1"

/// Why a line resolved to Unknown. Stable spellings — these appear in
/// extraction reports and tests in both ports.
public enum DecisionRejectReason: String, Equatable, Sendable {
    /// The entity slot is a pronoun ("he", "they", "it", ...) — F11.
    case pronounEntity = "pronoun_entity"
    /// The dimension has no registered rule (UnknownRule never proves).
    case unregisteredDimension = "unregistered_dimension"
    /// The rule's normalizer refused the value (ambiguous date,
    /// out-of-set enum token, malformed number) — F10 shape.
    case parseAmbiguous = "parse_ambiguous"
    /// The line carries a quoted span — reported text, not a decision (F12).
    case quotedSpan = "quoted_span"
    /// Hypothetical/reported-speech marker (if/would/might/reportedly/
    /// according to) — F12.
    case hypotheticalMarker = "hypothetical_marker"
    /// More than one `=` on the line.
    case multipleEquals = "multiple_equals"
    /// The line matches no accepted form at all.
    case noGrammarMatch = "no_grammar_match"
}

/// One accepted decision line, fully normalized and ready to file.
public struct ExtractedDecision: Equatable, Sendable {
    /// Entity exactly as written (canonicalization to a scoped conflict
    /// key happens at projection, not here — the extractor preserves
    /// the author's spelling for the KGFact subject).
    public let entity: String
    /// Canonical dimension (the registered rule's spelling).
    public let dimension: String
    /// The registered rule that accepted the value.
    public let ruleID: String
    /// Value exactly as written (the KGFact object).
    public let rawValue: String
    /// The rule-normalized typed value (proof-grade bytes).
    public let normalizedValue: TypedConflictValue
    /// For the `Replaces decision <id>:` form — the replaced result or
    /// fact id; nil for the other forms.
    public let replacesID: String?
    /// 1-based line number in the transcript.
    public let line: Int
}

/// One rejected line with its reason (deviation-only reporting).
public struct RejectedDecisionLine: Equatable, Sendable {
    public let line: Int
    public let reason: DecisionRejectReason
}

/// One transcript's extraction outcome.
public struct MeetingDecisionExtraction: Equatable, Sendable {
    public let decisions: [ExtractedDecision]
    /// Lines that LOOKED like decision lines (matched a form prefix)
    /// but were rejected. Ordinary prose lines are not listed.
    public let rejected: [RejectedDecisionLine]
}

/// The controlled-decision grammar (M0 §9). Deterministic; the registry
/// decides which dimensions exist and what values parse.
public enum MeetingDecisionExtractor {

    /// Pronoun list for the entity slot (case-insensitive, F11).
    static let pronouns: Set<String> = [
        "i", "you", "he", "she", "it", "we", "they",
        "him", "her", "them", "us", "me",
        "his", "hers", "its", "their", "theirs", "our", "ours",
        "this", "that", "these", "those", "someone", "everyone", "anybody",
    ]

    /// Hypothetical / reported-speech markers (whole-word, lowercased).
    static let hypotheticalMarkers = ["if", "would", "might", "reportedly"]
    /// Multi-word marker checked as a substring of the lowercased line.
    static let reportedSpeechPhrase = "according to"

    /// Extract every decision from `transcript` under `registry`.
    public static func extract(
        transcript: String,
        registry: ConflictRuleRegistry
    ) -> MeetingDecisionExtraction {
        var decisions: [ExtractedDecision] = []
        var rejected: [RejectedDecisionLine] = []

        for (index, rawLine) in transcript
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
        {
            let lineNumber = index + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard looksLikeDecisionLine(line) else { continue }

            switch parse(line: line, registry: registry) {
            case .success(var decision):
                decision = ExtractedDecision(
                    entity: decision.entity, dimension: decision.dimension,
                    ruleID: decision.ruleID, rawValue: decision.rawValue,
                    normalizedValue: decision.normalizedValue,
                    replacesID: decision.replacesID, line: lineNumber)
                decisions.append(decision)
            case .failure(let reason):
                rejected.append(RejectedDecisionLine(
                    line: lineNumber, reason: reason))
            }
        }
        return MeetingDecisionExtraction(decisions: decisions, rejected: rejected)
    }

    /// A line participates in the grammar only when it opens with one of
    /// the three accepted form prefixes (case-sensitive by design — the
    /// controlled register is part of the contract).
    static func looksLikeDecisionLine(_ line: String) -> Bool {
        line.hasPrefix("Decision:") || line.hasPrefix("Approved ")
            || line.hasPrefix("Replaces decision ")
    }

    private enum ParseResult {
        case success(ExtractedDecision)
        case failure(DecisionRejectReason)
    }

    private static func parse(
        line: String, registry: ConflictRuleRegistry
    ) -> ParseResult {
        // Whole-line rejections first (M0 §9): quoted spans, markers,
        // multiple `=` — these veto regardless of form.
        if line.contains("\"") || line.contains("“") || line.contains("”")
            || line.contains("'") {
            return .failure(.quotedSpan)
        }
        let lowered = line.lowercased()
        let words = lowered
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
        if hypotheticalMarkers.contains(where: words.contains)
            || lowered.contains(reportedSpeechPhrase) {
            return .failure(.hypotheticalMarker)
        }
        if line.filter({ $0 == "=" }).count > 1 {
            return .failure(.multipleEquals)
        }

        // Form 3 first (its prefix contains no `:` before the id).
        if line.hasPrefix("Replaces decision ") {
            let rest = String(line.dropFirst("Replaces decision ".count))
            guard let colon = rest.firstIndex(of: ":") else {
                return .failure(.noGrammarMatch)
            }
            let replacedID = String(rest[..<colon])
                .trimmingCharacters(in: .whitespaces)
            guard !replacedID.isEmpty else { return .failure(.noGrammarMatch) }
            let assignment = String(rest[rest.index(after: colon)...])
            return parseAssignment(
                assignment, replacesID: replacedID, registry: registry)
        }

        // Form 1: `Decision: <entity>.<dimension> = <value>`.
        if line.hasPrefix("Decision:") {
            let assignment = String(line.dropFirst("Decision:".count))
            return parseAssignment(
                assignment, replacesID: nil, registry: registry)
        }

        // Form 2: `Approved <dimension> for <entity>: <value>`.
        if line.hasPrefix("Approved ") {
            let rest = String(line.dropFirst("Approved ".count))
            guard let forRange = rest.range(of: " for ") else {
                return .failure(.noGrammarMatch)
            }
            let dimensionRaw = String(rest[..<forRange.lowerBound])
            let tail = String(rest[forRange.upperBound...])
            guard let colon = tail.firstIndex(of: ":") else {
                return .failure(.noGrammarMatch)
            }
            let entity = String(tail[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(tail[tail.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            return finish(
                entity: entity, dimensionRaw: dimensionRaw, value: value,
                replacesID: nil, registry: registry)
        }
        return .failure(.noGrammarMatch)
    }

    /// Parse ` <entity>.<dimension> = <value>` (forms 1 and 3).
    private static func parseAssignment(
        _ assignment: String, replacesID: String?,
        registry: ConflictRuleRegistry
    ) -> ParseResult {
        guard let equals = assignment.firstIndex(of: "=") else {
            return .failure(.noGrammarMatch)
        }
        let lhs = String(assignment[..<equals]).trimmingCharacters(in: .whitespaces)
        let value = String(assignment[assignment.index(after: equals)...])
            .trimmingCharacters(in: .whitespaces)
        // Entity may itself contain dots (scoped ids); the DIMENSION is
        // the last dot component.
        guard let lastDot = lhs.lastIndex(of: "."), lastDot != lhs.startIndex else {
            return .failure(.noGrammarMatch)
        }
        let entity = String(lhs[..<lastDot]).trimmingCharacters(in: .whitespaces)
        let dimensionRaw = String(lhs[lhs.index(after: lastDot)...])
        return finish(
            entity: entity, dimensionRaw: dimensionRaw, value: value,
            replacesID: replacesID, registry: registry)
    }

    /// Shared validation tail: entity → dimension → value, in the
    /// precedence tests pin (pronoun before unregistered before value).
    private static func finish(
        entity: String, dimensionRaw: String, value: String,
        replacesID: String?, registry: ConflictRuleRegistry
    ) -> ParseResult {
        guard !entity.isEmpty, !value.isEmpty else {
            return .failure(.noGrammarMatch)
        }
        if pronouns.contains(ConflictNormalize.enumToken(entity)) {
            return .failure(.pronounEntity)
        }
        // Exact dimension lookup first; then the `decision:` namespace —
        // the grammar's forms say "Decision"/"Approved", so a bare
        // `launch_date` reaches `decision:launch_date` without the
        // author spelling the namespace. Both lookups are exact-match;
        // nothing fuzzy.
        let dimension = ConflictNormalize.dimensionKey(dimensionRaw)
        guard let rule = registry.rule(forDimension: dimension)
            ?? registry.rule(forDimension: "decision:\(dimension)") else {
            return .failure(.unregisteredDimension)
        }
        guard let normalized = rule.normalize(value) else {
            return .failure(.parseAmbiguous)
        }
        return .success(ExtractedDecision(
            entity: entity, dimension: rule.dimension, ruleID: rule.ruleID,
            rawValue: value, normalizedValue: normalized,
            replacesID: replacesID, line: 0))
    }
}
