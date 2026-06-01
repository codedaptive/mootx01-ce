// LatticeResolver.swift
//
// Resolves a term's normalized/stemmed tokens to an entry in the
// MDCC canon (from LatticeLib). This is the grounding step of
// EideticLib.lookup: it replaces the former UDC pipeline
// (GazetteerMatcher + Classifier + UDCSchedule), which classified
// against the CC-BY-SA UDC schedule. The MDCC canon is CC0/public-
// domain (assembled from Wikidata CC0), so it ships in the default
// bundle with no licensing obligation.
//
// MATCHING STRATEGY (label-only, deterministic)
// =============================================
//
// LatticeEntry carries {code, sourceIdentity, label, classBase} and no
// aliases field, so resolution matches the input against the entry
// LABEL only. (An aliases field would improve recall; recorded as a
// follow-up in TASK_MDCC_03_BLAST_RADIUS.md.) Each label is run
// through the same Tokenizer/Normalizer/Stemmer surfaces the input
// goes through, so morphological variants align on either the
// normalized or the stemmed form.
//
// An input position i matches a candidate when its normalized form
// is in the label's normalized token set OR its stemmed form is in
// the label's stemmed token set.
//
// RANKING (lexicographic, maximized; ascending code as final tiebreak)
// --------------------------------------------------------------------
//
//   (exactLabel, matchedInputCount, -extraLabelTokens, -codeOrder)
//
//   exactLabel        = 1 when the label's normalized token set
//                       equals the input's normalized token set
//                       (the input names the concept exactly), else 0.
//   matchedInputCount = number of input positions that matched.
//   extraLabelTokens  = label tokens not present in the input; fewer
//                       is better, so a concise precise label
//                       ("philosophy") beats a longer one that merely
//                       contains the term ("moral philosophy").
//   codeOrder         = ascending code string, the deterministic
//                       final tiebreak so duplicate labels resolve
//                       to the lowest (most canonical) code.
//
// An entry is a candidate only when matchedInputCount >= 1. With no
// candidate the resolver returns nil and lookup yields an empty
// anchor — never a fallback code.

import Foundation
import LatticeLib

/// The outcome of resolving a term against the MDCC canon: the
/// resolved code, its CC0 Wikidata source identity, and a confidence
/// packed into the substrate's 6-bit provenance confidence value set.
public struct LatticeResolution: Equatable, Sendable {

    /// The resolved MDCC code (present in the bundled canon).
    public let code: String

    /// The canon entry's source identity — its CC0 Wikidata Q-ID.
    public let sourceIdentity: String

    /// Confidence in the substrate provenance value set:
    /// 0=null, 16=low, 32=medium, 48=high, 56=verified.
    public let confidence: UInt8

    public init(code: String, sourceIdentity: String, confidence: UInt8) {
        self.code = code
        self.sourceIdentity = sourceIdentity
        self.confidence = confidence
    }
}

public enum LatticeResolver {

    /// Resolve normalized/stemmed input tokens to an MDCC canon entry.
    /// Returns nil when no entry shares a token with the input.
    ///
    /// - Parameters:
    ///   - normalized: the input tokens, normalized (lowercased).
    ///   - stemmed: the same tokens, stemmed (Porter2).
    ///   - canon: the bundled MDCC canon to resolve against.
    public static func resolve(
        normalized: [String],
        stemmed: [String],
        canon: LatticeCanon
    ) -> LatticeResolution? {
        guard !normalized.isEmpty else { return nil }

        // One linear scan over the canon. Per-entry scoring (label
        // tokenization, the match count, and the ranking comparison)
        // is kept inline rather than split into helpers so the whole
        // deterministic ranking vector documented in the file header
        // reads top to bottom at its one call site.
        let inputNormSet = Set(normalized)
        let inputStemSet = Set(stemmed)

        // Running best, compared on the ranking vector documented
        // at the top of the file.
        var best: (resolution: LatticeResolution, exact: Bool, matched: Int, extra: Int)?

        for entry in canon.entries {
            let labelTokens = Tokenizer.tokenize(entry.label).map(Normalizer.normalize)
            guard !labelTokens.isEmpty else { continue }
            let labelNormSet = Set(labelTokens)
            let labelStemSet = Set(labelTokens.map(Stemmer.stem))

            // Count input positions that hit the label on either surface.
            var matched = 0
            for i in 0..<normalized.count {
                if labelNormSet.contains(normalized[i])
                    || labelStemSet.contains(stemmed[i]) {
                    matched += 1
                }
            }
            guard matched >= 1 else { continue }

            let exact = labelNormSet == inputNormSet
            // Label tokens the input did not supply (precision penalty).
            let extra = labelNormSet.subtracting(inputNormSet)
                .subtracting(inputStemSet).count

            let confidence = confidenceFor(
                exact: exact,
                matched: matched,
                inputCount: normalized.count
            )
            let candidate = LatticeResolution(
                code: entry.code,
                sourceIdentity: entry.sourceIdentity,
                confidence: confidence
            )

            if best == nil
                || beats(
                    (candidate, exact, matched, extra),
                    over: best!
                ) {
                best = (candidate, exact, matched, extra)
            }
        }

        return best?.resolution
    }

    /// True when `a` strictly beats `b` on the ranking vector:
    /// (exactLabel, matchedInputCount, -extraLabelTokens, -codeOrder).
    private static func beats(
        _ a: (resolution: LatticeResolution, exact: Bool, matched: Int, extra: Int),
        over b: (resolution: LatticeResolution, exact: Bool, matched: Int, extra: Int)
    ) -> Bool {
        if a.exact != b.exact { return a.exact }
        if a.matched != b.matched { return a.matched > b.matched }
        if a.extra != b.extra { return a.extra < b.extra }
        // Final deterministic tiebreak: lowest (most canonical) code.
        return a.resolution.code < b.resolution.code
    }

    /// Confidence mapping for an MDCC resolution. An exact label name
    /// is high confidence; full coverage of the input by a longer
    /// label is medium; a partial hit is low.
    private static func confidenceFor(
        exact: Bool,
        matched: Int,
        inputCount: Int
    ) -> UInt8 {
        if exact { return 48 }            // high
        if matched == inputCount { return 32 }  // medium: input fully covered
        return 16                         // low: partial hit
    }
}
