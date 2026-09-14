import AriaMCPWire

// RecipeTools.swift
//
// Shared read-side helpers for the ARIA v2 lens and recall lowers:
// structured drawer hydration, the dense-row sensitivity gate, the
// conflict-projection section, and grounding-term extraction for
// `moot_synthesize`. Tool descriptors live in the v2 catalog
// (`AriaV2SelectedCatalog`); nothing here is advertised in `tools/list`.
//
import Foundation
import GeniusLocusKit
import NeuronKit
import LocusKit
import CognitionKit

/// Namespace for the CognitionKit recipe tool surface. No instances.
enum RecipeTools {

    /// Fetch drawers by ID through the gated RecallFrame (COMPOSER-02B).
    ///
    /// THE EMPTY `filterChain` IS LOAD-BEARING, NOT AN ABSENT ARGUMENT.
    /// `BitmapEvaluator.insertDefaults` inserts `.sensitivityAtMost(.elevated)`
    /// so restricted/secret drawers never appear in the result.  Do NOT
    /// substitute the frameless `estate.getDrawers(ids:hydrationLevel:)`.
    ///
    /// `filterChain` carries the CALLER's filter when the tool surface
    /// accepts one (connected recall passes it so walk-reachable rows cannot
    /// bypass the filter at render, Wave-3 G1). Default structured hydration:
    /// content blobs are NOT loaded; recall-recipe content comes from the match.
    /// Pass `.full` when the caller needs `drawer.content` for bestSpan — the
    /// lens dense-field path uses `.full` so that normalizeValue operates on the
    /// real body rather than the empty string that structured hydration returns
    /// (matching Rust get_drawers_matching_frame which always loads full rows).
    /// Gated ids are ABSENT from the returned map — callers render opaque rows
    /// (id visible, subject withheld) for absent ids, which keeps the gate
    /// an accurate containment boundary without changing result counts.
    static func structuredDrawersByID(
        ids: [String], estate: Estate, filterChain: [Filter] = [],
        hydrationLevel: HydrationLevel = .structured
    ) async throws -> [String: Drawer] {
        guard !ids.isEmpty else { return [:] }
        let fetched = try await estate.getDrawers(
            ids: ids,
            matchingFrame: RecallFrame(filterChain: filterChain, hydrationLevel: hydrationLevel),
            hydrationLevel: hydrationLevel)
        return Dictionary(uniqueKeysWithValues: fetched.admissible.map { ($0.id, $0) })
    }

    // MARK: - typed conflict projection section (DCP M4)

    /// Render the typed conflict-projection sweep as the ADDITIVE report
    /// section every contradiction surface appends (M0 §7):
    /// moot_hunt_contradictions, moot_dream, and moot_lens_contradiction
    /// all route through this one renderer so the lines never drift.
    ///
    /// Redaction (M0 §8, ceiling = MAX endpoint sensitivity, no grant
    /// plumbing in v0.1 — same fixed posture as the lexical hunter):
    /// - ceiling ≤ elevated (raw 16): full block incl. dense rows.
    /// - restricted (raw 32): one line naming only the coordinate
    ///   DIGEST — no source ids, no value digests (enum domains are
    ///   small, digests would be guessable), no dense rows.
    /// - secret (raw 48): counted in `proven: N`, no block at all.
    ///
    /// `lexicalCandidates` is the borderline count from the lexical
    /// hunter (the `candidates:` relabel); pass nil on surfaces with no
    /// lexical lane (the lens).
    static func conflictProjectionSection(
        _ sweep: ConflictProjectionSweepReport,
        denseRows: [String: String],
        lexicalCandidates: Int?
    ) -> [String] {
        var lines: [String] = [
            "proven: \(sweep.counts.provenContradiction)",
            "historical: \(sweep.counts.historicalSuccession)",
            "compatible: \(sweep.counts.compatiblePlurality)",
        ]
        if let candidates = lexicalCandidates {
            lines.append("candidates: \(candidates)")
        }
        // Unparsed facts and unjudgeable pairs share the line: both are
        // "the typed lane saw it and refused to guess".
        lines.append("unknown_or_invalid: "
            + "\(sweep.counts.unknownOrInvalid + sweep.diagnostics.unparsed)")
        lines.append("coverage: \(sweep.diagnostics.projected)/\(sweep.diagnostics.scanned)")
        if sweep.truncatedBuckets > 0 {
            // Deviation-only line (M0 §7): silence means no bucket hit
            // its cap.
            lines.append("truncated_buckets: \(sweep.truncatedBuckets)")
        }
        let secretRaw = AdjectiveSensitivity.secret.rawValue
        let restrictedRaw = AdjectiveSensitivity.restricted.rawValue
        for finding in sweep.proven {
            if finding.sensitivityCeilingRaw >= secretRaw { continue }
            let outcome = finding.outcome
            if finding.sensitivityCeilingRaw >= restrictedRaw {
                lines.append("  a conflicting claim exists at "
                    + "\(outcome.coordinateDigest) [restricted]")
                continue
            }
            lines.append("  PROVEN \(outcome.resultID)")
            lines.append("    rule: \(outcome.ruleID)@\(outcome.ruleVersion)")
            lines.append("    coordinate: \(outcome.key)|\(outcome.dimension)")
            lines.append("    values: \(outcome.valueDigests.joined(separator: " vs "))")
            lines.append("    time: \(outcome.temporalBases.joined(separator: " | "))")
            lines.append("    reasons: "
                + outcome.reasons.map(\.rawValue).joined(separator: ", "))
            for id in outcome.sourceDrawerIDs {
                lines.append("    \(denseRows[id] ?? "\(id) · - · - · - · -")")
            }
        }
        for finding in sweep.historical where finding.sensitivityCeilingRaw < restrictedRaw {
            let outcome = finding.outcome
            lines.append("  HISTORICAL \(outcome.resultID) "
                + "\(outcome.key)|\(outcome.dimension) ("
                + outcome.reasons.map(\.rawValue).joined(separator: ", ") + ")")
        }
        return lines
    }


    // MARK: - Argument decoding

    /// Stopwords excluded from grounding-term extraction: question scaffolding
    /// and function words that would match nearly every memory and destroy the
    /// cue's selectivity. Deliberately small — an over-eager list starts
    /// eating content words. MUST stay byte-identical to Rust
    /// `GROUNDING_STOPWORDS` in recipe_tools.rs (conformance-checked there).
    private static let groundingStopwords: Set<String> = [
        "the", "and", "for", "are", "was", "were", "has", "have", "had",
        "did", "does", "not", "with", "that", "this", "from", "they",
        "their", "them", "then", "than", "there", "these", "those", "you",
        "your", "what", "when", "where", "which", "who", "whom", "why",
        "how", "will", "would", "could", "should", "about", "been", "being",
        "into", "over", "under", "after", "before", "between", "during",
        "any", "all", "each", "most", "some", "such", "can", "may", "might",
        "must", "shall", "its", "his", "her", "him", "she", "our", "out",
        "but", "per", "via", "also", "just", "only", "very", "much", "more",
    ]

    /// Extracts the distinctive grounding terms from a free-text query:
    /// alphanumeric runs, lowercased (content matching is case-insensitive on
    /// both ports), dropping stopwords and short fragments (< 3 chars unless
    /// they carry a digit — "42" or "3b" are distinctive, "at" is not),
    /// deduplicated in first-appearance order, capped at 12 terms so a pasted
    /// paragraph cannot degenerate into an unbounded OR. Deterministic pure
    /// function of the query — MUST stay behavior-identical to Rust
    /// `grounding_terms` in recipe_tools.rs.
    static func groundingTerms(from query: String) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for raw in query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let token = raw.lowercased()
            let hasDigit = token.contains { $0.isNumber }
            guard token.count >= 3 || hasDigit else { continue }
            guard !groundingStopwords.contains(token) else { continue }
            guard seen.insert(token).inserted else { continue }
            terms.append(token)
            if terms.count == 12 { break }
        }
        return terms
    }

}
