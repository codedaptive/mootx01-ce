// FDCMatcher.swift
//
// FDC runtime encoder, Steps 4–5 (cookbook §5–§6): match an input text's
// concept bag against the code signatures, then descend the decimal frame to
// the most specific well-supported code.
//
//   Step 4 (§5.2/§5.3): score[code] += bag[term] for every term shared with
//                       the code's signature (inverted-index single-pass scan,
//                       the deterministic equivalent of the spec's Aho-Corasick
//                       scan over concept-id keys). Empty score -> UNRESOLVED.
//   Step 5 (§6):        start at argmax(score) (ties -> lowest code), then walk
//                       down children while a child's bag overlap meets
//                       STOP_THRESHOLD; return the deepest such code.
//
// `encode` is a pure function of the input text and the pinned artifacts
// (lexicon, signatures, frame) — the agreement property.

import Foundation

public struct FDCMatcher {

    /// Pinned descent cutoff (§6.1). v1.0 value is TBD against real signatures;
    /// `1` (any overlap continues) is the testing default and MUST NOT ship.
    public let stopThreshold: Int

    private let lexicon: CanonicalizationLexicon
    private let frame: FDCFrame
    private let sigTerms: [String: Set<String>]    // code -> signature term set
    private let index: [String: [String]]          // term -> codes (sorted)

    public init(
        lexicon: CanonicalizationLexicon,
        frame: FDCFrame,
        signatures: [String: Set<String>],
        stopThreshold: Int = 1
    ) {
        self.lexicon = lexicon
        self.frame = frame
        self.sigTerms = signatures
        self.stopThreshold = stopThreshold
        var idx: [String: [String]] = [:]
        for (code, terms) in signatures { for t in terms { idx[t, default: []].append(code) } }
        for k in idx.keys { idx[k]!.sort() }       // deterministic order
        self.index = idx
    }

    /// Encode `text` to an FDC code, or `nil` for UNRESOLVED. Never guesses.
    public func encode(_ text: String) -> String? {
        let bag = BagBuilder.bag(text, lexicon: lexicon)
        guard !bag.isEmpty else { return nil }

        // Step 4 — match + score (§5.2/§5.3).
        var score: [String: Int] = [:]
        for (term, n) in bag {
            guard let codes = index[term] else { continue }
            for code in codes { score[code, default: 0] += n }
        }
        guard !score.isEmpty else { return nil }   // §5.2.3 — UNRESOLVED, no guess

        // argmax: highest score, ties broken by lowest code lexicographically.
        var node = ""
        var nodeScore = Int.min
        for (code, s) in score where s > nodeScore || (s == nodeScore && code < node) {
            node = code; nodeScore = s
        }

        // Step 5 — frame descent (§6.1).
        while true {
            var best: String?
            var bestOverlap = 0
            for child in frame.children(of: node) {
                guard let terms = sigTerms[child.code] else { continue }
                var overlap = 0
                for (term, n) in bag where terms.contains(term) { overlap += n }
                guard overlap >= stopThreshold else { continue }
                if overlap > bestOverlap || (overlap == bestOverlap && (best == nil || child.code < best!)) {
                    best = child.code; bestOverlap = overlap
                }
            }
            guard let next = best else { break }
            node = next
        }
        return node
    }
}
