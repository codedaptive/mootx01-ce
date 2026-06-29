// ContextSynthesizer.swift
//
// Reads-only synthesis of a `RecallStream.Page` into a
// `ContextDocument` suitable for foundation-model consumption. Per
// NEURONKIT_SPEC § 4.2 and invariant C-9, the synthesizer never
// writes to the substrate and calls no estate verbs. Pure, ephemeral.
//
// The `estate:` parameter is preserved from the spec signature for
// shape parity with § 4.2 and to keep future evolution open (the
// boundary can grow read-only queries without forcing every caller
// to add an argument). Under C-9 the parameter is reserved and
// untouched — verb dispatch through `glk.recall` or any other verb
// is prohibited here.

import Foundation
import GeniusLocusKit
import LocusKit

/// Ephemeral context document produced by `ContextSynthesizer`. Per
/// spec § 4.2 — handed to a foundation model, never written to the
/// substrate, never persisted. Equatable for test conformance and
/// snapshot parity against the Rust version.
public struct ContextDocument: Sendable, Equatable, Codable {

    /// Short prose summary of the recalled set (one or two sentences).
    /// Deterministic — derived from the drawer content shingles, not
    /// from a model.
    public let summary: String

    /// Salient repeating patterns observed across the recalled set.
    /// Stable order: descending by occurrence, ties broken by first
    /// appearance.
    public let patterns: [String]

    /// Proportion of recalled drawers whose adjective-bitmap `state`
    /// is the "currently believed" cluster per LocusKit spec § 6.1.
    /// In [0, 1]; reported as Float so the round-trip is identical
    /// to the Rust f32 version.
    public let successRate: Float

    /// Mean reward across the recalled set. Drawer.reward is not a
    /// substrate field today, so this value is 0.0 for v0.1 callers.
    /// Carried for shape parity with the spec; the field stays in
    /// the public surface so the day a reward attribute lands the
    /// caller does not change.
    public let averageReward: Float

    /// Recommendations distilled from the page. Deterministic strings
    /// built from the dominant patterns; never invented by a model.
    public let recommendations: [String]

    /// Key insights — first-line excerpts from the highest-relevance
    /// drawers in the page, in stream order.
    public let keyInsights: [String]

    public init(
        summary: String,
        patterns: [String],
        successRate: Float,
        averageReward: Float,
        recommendations: [String],
        keyInsights: [String]
    ) {
        self.summary = summary
        self.patterns = patterns
        self.successRate = successRate
        self.averageReward = averageReward
        self.recommendations = recommendations
        self.keyInsights = keyInsights
    }
}

/// Namespace for the synthesis function. Declared as an enum (no
/// cases) so it cannot be instantiated and so test code references
/// the function with `ContextSynthesizer.synthesize(...)`, matching
/// the spec's prose.
public enum ContextSynthesizer {

    /// Synthesize a `ContextDocument` from one `RecallStream.Page`.
    ///
    /// **C-9 invariant:** This function performs no estate write,
    /// invokes no estate verb, and accesses no substrate state
    /// beyond what is already materialised in `page.rows`. The
    /// `estate:` parameter is reserved and untouched — present to
    /// match the spec signature and to allow future read-only verb
    /// composition without a source break for callers. The compiler
    /// will warn if it is unused; the underscore-discard below
    /// records the intentional non-use so future maintainers see
    /// the invariant in code.
    public static func synthesize(
        from page: RecallStream.Page,
        estate: EstateHandle
    ) async throws -> ContextDocument {
        _ = estate // C-9: reserved, never consulted. See header doc.
        return ContextSynthesisEngine.synthesize(page: page)
    }
}

/// Pure synthesis engine. Module-internal so the Swift conformance
/// tests and the Rust version exercise the same deterministic math
/// against shared vectors. No `async`, no estate handle — just the
/// drawer rows.
internal enum ContextSynthesisEngine {

    static func synthesize(page: RecallStream.Page) -> ContextDocument {
        let rows = page.rows
        if rows.isEmpty {
            return ContextDocument(
                summary: "",
                patterns: [],
                successRate: 0,
                averageReward: 0,
                recommendations: [],
                keyInsights: []
            )
        }

        let summary = makeSummary(rows: rows)
        let patterns = topPatterns(rows: rows, maxCount: 5)
        let successRate = currentlyBelievedRate(rows: rows)
        let averageReward: Float = 0 // No reward field on Drawer at v0.1 — see spec note.
        let recommendations = makeRecommendations(patterns: patterns)
        let keyInsights = makeKeyInsights(rows: rows, maxCount: 3)

        return ContextDocument(
            summary: summary,
            patterns: patterns,
            successRate: successRate,
            averageReward: averageReward,
            recommendations: recommendations,
            keyInsights: keyInsights
        )
    }

    /// Build a one-line summary that names the page row count, the
    /// most frequent parent node, and the dominant content-kind. Stable
    /// across runs — no clocks, no randomness.
    static func makeSummary(rows: [Drawer]) -> String {
        let count = rows.count
        let topNode = mostFrequent(rows.map { $0.parentNodeId }) ?? "(no node)"
        return "\(count) drawers; dominant node \(topNode)."
    }

    /// Standard English stopwords excluded from pattern extraction. These high-
    /// frequency function words and bare 4-digit years add no semantic signal
    /// and would dominate the pattern list when present in a corpus.
    ///
    /// Mirrors the Rust `STOPWORDS` constant in `context_synthesizer.rs`
    /// byte-for-byte so conformance test vectors produce identical output.
    static let stopwords: Set<String> = [
        "this", "that", "with", "from", "they", "them", "their", "there",
        "were", "have", "been", "will", "would", "could", "should", "about",
        "when", "then", "than", "also", "into", "your", "more", "some",
        "what", "which", "these", "those", "just", "like", "over", "such",
        "only", "very", "even", "most", "both", "each", "here", "after",
        "well", "back", "much", "many", "make", "time", "know", "take",
        "long", "made", "come", "want", "used", "same", "need",
    ]

    /// True when `token` is a bare 4-digit year (1000–2999) or a pure numeric
    /// string — neither carries semantic meaning as a pattern.
    private static func isBareYearOrNumeric(_ token: String) -> Bool {
        guard token.allSatisfy({ $0.isNumber }) else { return false }
        if token.count == 4,
           let year = Int(token), year >= 1000, year <= 2999 { return true }
        // Pure numeric strings (any length) are also excluded.
        return true
    }

    /// Tokenise each drawer's content into 4-or-longer lowercase
    /// alphanumeric words, then return the most frequent ones across
    /// the page in descending order. Stable: ties break by first
    /// appearance.
    ///
    /// Excludes stopwords and bare numeric strings (including years)
    /// so high-frequency function words and date literals do not dominate
    /// the pattern list. Mirrors the Rust `top_patterns` filter.
    static func topPatterns(rows: [Drawer], maxCount: Int) -> [String] {
        var counts: [String: Int] = [:]
        var firstSeen: [String: Int] = [:]
        var insertionOrder = 0
        for row in rows {
            for token in tokens(row.content) where token.count >= 4
                && !stopwords.contains(token)
                && !isBareYearOrNumeric(token) {
                counts[token, default: 0] += 1
                if firstSeen[token] == nil {
                    firstSeen[token] = insertionOrder
                    insertionOrder += 1
                }
            }
        }
        // Order: count desc, then first-seen asc (stable). Use the
        // token string as a final tiebreaker so output is identical
        // across language versions even when counts and first-seen ties
        // align.
        let ordered = counts.keys.sorted { lhs, rhs in
            let cl = counts[lhs] ?? 0
            let cr = counts[rhs] ?? 0
            if cl != cr { return cl > cr }
            let fl = firstSeen[lhs] ?? Int.max
            let fr = firstSeen[rhs] ?? Int.max
            if fl != fr { return fl < fr }
            return lhs < rhs
        }
        return Array(ordered.prefix(maxCount))
    }

    /// Fraction of rows whose adjective-bitmap `state` is in the
    /// "currently believed" cluster. Computed via LocusKit's
    /// extension predicate `isCurrentlyBelieved` so the math stays
    /// aligned with the substrate definition.
    static func currentlyBelievedRate(rows: [Drawer]) -> Float {
        guard !rows.isEmpty else { return 0 }
        let count = rows.reduce(into: 0) { acc, row in
            if row.isCurrentlyBelieved { acc += 1 }
        }
        return Float(count) / Float(rows.count)
    }

    /// Build deterministic recommendations from the top patterns. For
    /// each pattern, emit one recommendation; if no patterns surfaced,
    /// return a single neutral string so the caller never sees an
    /// empty list when the page itself was non-empty.
    static func makeRecommendations(patterns: [String]) -> [String] {
        guard !patterns.isEmpty else {
            return ["No dominant pattern detected; consider broadening the recall frame."]
        }
        return patterns.map { "Explore further evidence about '\($0)'." }
    }

    /// First-line excerpts from up to `maxCount` rows, in stream
    /// order. The "first line" is the substring up to the first
    /// newline, or the full content if there is no newline.
    static func makeKeyInsights(rows: [Drawer], maxCount: Int) -> [String] {
        rows.prefix(maxCount).map { row in
            if let nl = row.content.firstIndex(of: "\n") {
                return String(row.content[..<nl])
            }
            return row.content
        }
    }

    // MARK: - private helpers

    /// Most frequent element in a sequence, ties broken by first
    /// appearance. Nil for an empty sequence.
    static func mostFrequent<T: Hashable>(_ values: [T]) -> T? {
        guard !values.isEmpty else { return nil }
        var counts: [T: Int] = [:]
        var firstSeen: [T: Int] = [:]
        var order = 0
        for v in values {
            counts[v, default: 0] += 1
            if firstSeen[v] == nil {
                firstSeen[v] = order
                order += 1
            }
        }
        return counts.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return (firstSeen[lhs.key] ?? Int.max) > (firstSeen[rhs.key] ?? Int.max)
        }?.key
    }

    /// Lowercase alphanumeric tokens. Splits on any non-letter,
    /// non-digit character so behaviour is locale-free and identical
    /// across versions for the ASCII conformance vectors used in tests.
    static func tokens(_ s: String) -> [String] {
        s.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
    }
}
